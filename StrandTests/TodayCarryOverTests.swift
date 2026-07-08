import XCTest
import WhoopStore
@testable import Strand

/// #543 — the carry-over selector that keeps the WHOLE recovery side populated at the logical-day
/// rollover. When today isn't scored yet (the new night isn't computed until you wear it tonight), every
/// recovery-derived read-out (the Charge ring, the HRV / resting-HR / respiratory / SpO₂ tiles, the
/// Synthesis / Contributors / Readiness reads) carries the LAST scored day's value, clearly stamped
/// "Last night · <date>", instead of blanking to "No Data" while live HR ticks — the confusing state the
/// reporter hit. This pins the GATE + SELECTION that drives all of that: it must only carry on today,
/// only when today is unscored, only when not mid-calibration, must exclude today's own (still-nil) row,
/// and must pick the freshest scored prior day. Mirrors the Android `lastScoredRecoveryDay` test.
final class TodayCarryOverTests: XCTestCase {

    /// A day row with an optional recovery + vitals — enough to exercise the selector + "real value wins".
    private func day(_ key: String, recovery: Double?,
                     hrv: Double? = nil, rhr: Int? = nil, spo2: Double? = nil, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery,
                    strain: nil, exerciseCount: nil, spo2Pct: spo2, skinTempDevC: nil, respRateBpm: resp)
    }

    // MARK: gate

    func testCarriesTheFreshestScoredPriorDay_whenTodayUnscoredAndPastCalibration() {
        let days = [day("2026-06-17", recovery: 60), day("2026-06-18", recovery: 72),
                    day("2026-06-19", recovery: nil)]   // today, not scored yet
        let carried = TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: "2026-06-19",
            isToday: true, todayScored: false, isCalibrating: false)
        XCTAssertEqual(carried?.day, "2026-06-18", "must carry the most recent SCORED prior day")
        XCTAssertEqual(carried?.recovery, 72)
    }

    func testNothingCarried_whenTodayIsAlreadyScored() {
        // Today's own value must win — never carry when there's a real today.
        let days = [day("2026-06-18", recovery: 72), day("2026-06-19", recovery: 55)]
        XCTAssertNil(TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: "2026-06-19",
            isToday: true, todayScored: true, isCalibrating: false))
    }

    func testNothingCarried_whileCalibrating() {
        // Calibration owns its own "N of 4" copy on the Charge ring — the carry-over must stand down.
        let days = [day("2026-06-18", recovery: 72), day("2026-06-19", recovery: nil)]
        XCTAssertNil(TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: "2026-06-19",
            isToday: true, todayScored: false, isCalibrating: true))
    }

    func testNothingCarried_onANavigatedPastDay() {
        // A navigated past day with no score is missing data, not a rollover — never carry.
        let days = [day("2026-06-17", recovery: 60), day("2026-06-18", recovery: 72)]
        XCTAssertNil(TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: "2026-06-18",
            isToday: false, todayScored: false, isCalibrating: false))
    }

    // MARK: selection honesty

    func testExcludesTodaysOwnKey_soItNeverEchoesToday() {
        // Today's row carries vitals but no recovery — it must NOT be the carried row (we'd be echoing
        // today's partial data as "last night"). The prior scored day is chosen instead.
        let days = [day("2026-06-18", recovery: 72),
                    day("2026-06-19", recovery: nil, hrv: 40)]   // today: vitals but unscored
        let carried = TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: "2026-06-19",
            isToday: true, todayScored: false, isCalibrating: false)
        XCTAssertEqual(carried?.day, "2026-06-18")
    }

    func testNil_whenNoPriorDayWasEverScored() {
        // A genuinely-never-scored history carries nothing — the tiles honestly stay "—".
        let days = [day("2026-06-18", recovery: nil), day("2026-06-19", recovery: nil)]
        XCTAssertNil(TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: "2026-06-19",
            isToday: true, todayScored: false, isCalibrating: false))
    }

    // MARK: future-day guard (#547)

    func testNeverCarriesAFutureDatedRow() {
        // A bad-clock strap (or a pre-heal DB) can leave a future-dated scored row. The carry-over must
        // NEVER surface it as "Last night · 12 Jul" — it must pick the freshest genuine PRIOR day instead.
        let days = [day("2026-06-17", recovery: 60), day("2026-06-18", recovery: 72),
                    day("2026-06-19", recovery: nil),    // today, not scored yet
                    day("2026-07-12", recovery: 80)]     // STRAY FUTURE row (the "12 Jul" bug)
        let carried = TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: "2026-06-19",
            isToday: true, todayScored: false, isCalibrating: false)
        XCTAssertEqual(carried?.day, "2026-06-18", "a future-dated row must never be carried as last night")
        XCTAssertEqual(carried?.recovery, 72)
    }

    func testNothingCarried_whenOnlyFutureRowsExistBesidesToday() {
        // If the ONLY scored rows are future-dated, the carry-over honestly returns nil (tiles stay "—")
        // rather than reaching forward in time.
        let days = [day("2026-06-19", recovery: nil),    // today, unscored
                    day("2026-07-12", recovery: 80)]     // future-only
        XCTAssertNil(TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: "2026-06-19",
            isToday: true, todayScored: false, isCalibrating: false))
    }

    func testCarriedRow_keepsItsOwnMissingMetricsAsNil_neverFabricated() {
        // The carried row is a real DailyMetric: a metric it genuinely lacks (e.g. a BLE-only night with
        // no SpO₂) stays nil on the carried row, so the SpO₂ tile still resolves to "—" rather than a made
        // up number. The selector returns the row verbatim; the per-tile fallback reads the real fields.
        let days = [day("2026-06-18", recovery: 72, hrv: 55, rhr: 50, spo2: nil, resp: 14.2),
                    day("2026-06-19", recovery: nil)]
        let carried = TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: "2026-06-19",
            isToday: true, todayScored: false, isCalibrating: false)
        XCTAssertEqual(carried?.avgHrv, 55)
        XCTAssertEqual(carried?.restingHr, 50)
        XCTAssertNil(carried?.spo2Pct, "a metric the carried night lacks must stay nil, never fabricated")
        XCTAssertEqual(carried?.respRateBpm, 14.2)
    }

    // MARK: recency cap + relabel (#779)

    func testCarryWithinTwoDays_readsLastNight() {
        // A genuine post-rollover carry (yesterday's score on today) stays "Last night · <date>".
        XCTAssertFalse(TodayView.isCarryStale(priorDayKey: "2026-06-18", todayKey: "2026-06-19"))
        XCTAssertEqual(TodayView.carriedCaption(priorDayKey: "2026-06-18", todayKey: "2026-06-19"),
                       "Last night · " + dMMM("2026-06-18"))
    }

    func testCarryAtExactlyTwoDays_stillReadsLastNight() {
        // The cap is inclusive at 2 days, so a strap off for a day still reads as a recent "Last night".
        XCTAssertFalse(TodayView.isCarryStale(priorDayKey: "2026-06-17", todayKey: "2026-06-19"))
    }

    func testCarryOlderThanTwoDays_relabelsLatestSleep() {
        // #779: a weeks-old import (here ~4 weeks) is still carried (not a bare blank) but must NOT be
        // labelled "Last night"; it relabels to "Latest sleep · <date>".
        XCTAssertTrue(TodayView.isCarryStale(priorDayKey: "2026-05-22", todayKey: "2026-06-19"))
        XCTAssertEqual(TodayView.carriedCaption(priorDayKey: "2026-05-22", todayKey: "2026-06-19"),
                       "Latest sleep · " + dMMM("2026-05-22"))
    }

    func testCarryJustBeyondCap_relabelsLatestSleep() {
        // 3 days out is the first day past the cap.
        XCTAssertTrue(TodayView.isCarryStale(priorDayKey: "2026-06-16", todayKey: "2026-06-19"))
    }

    func testStaleness_unparseableKeyReadsFresh_neverOverClaims() {
        // A malformed key must never be reported stale (we'd rather under-claim than wrongly relabel).
        XCTAssertFalse(TodayView.isCarryStale(priorDayKey: "not-a-date", todayKey: "2026-06-19"))
    }

    /// Locale-formatted "d MMM" matching the production `lastChargeDateFmt`, so the caption assertions
    /// stay stable regardless of the test host's locale.
    private func dMMM(_ key: String) -> String {
        let parse = DateFormatter(); parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: key) else { return key }
        let f = DateFormatter(); f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: d)
    }
}
