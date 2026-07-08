import XCTest
@testable import WhoopStore

/// The recovery-INDEPENDENT overnight-vitals carry behind the v8 Today rollover fix. After the 04:00
/// logical-day rollover, before tonight's sleep is scored, today's row has no HRV / resting-HR /
/// respiratory yet, so the recovery-vitals read-outs must fall back to the last night that recorded them
/// instead of rendering "–". Unlike the whole-row Charge carry (`Repository.widgetAnchor` /
/// `TodayView.lastScoredRecoveryDay`), this selector does NOT gate on the prior night's recovery — a night
/// with real HRV/RHR but a null recovery is a valid vitals source. It only supplies the FALLBACK; the call
/// sites read each vital today-first, so today's own value always wins and the selector never overrides it.
final class DailyMetricLastVitalsDayTests: XCTestCase {

    /// A day row with optional recovery + vitals — mirrors the classic carry-over test's helper.
    private func day(_ key: String, recovery: Double? = nil,
                     hrv: Double? = nil, rhr: Int? = nil, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery,
                    strain: nil, exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: resp)
    }

    // MARK: everyday rollover

    func testCarriesYesterdaysVitals_whenTodayHasNoneYet() {
        // The post-04:00 state: yesterday scored with vitals, today's row exists but is empty. The carry
        // must return yesterday so HRV/RHR/Resp keep reading instead of blanking to "–".
        let days = [day("2026-06-17", recovery: 60, hrv: 50, rhr: 54, resp: 14.0),
                    day("2026-06-18", recovery: 72, hrv: 58, rhr: 51, resp: 13.5),
                    day("2026-06-19")]   // today, no vitals yet
        let carried = DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(carried?.day, "2026-06-18", "must carry the freshest prior day that has vitals")
        XCTAssertEqual(carried?.avgHrv, 58)
        XCTAssertEqual(carried?.restingHr, 51)
        XCTAssertEqual(carried?.respRateBpm, 13.5)
    }

    // MARK: recovery-INDEPENDENT — the sub-case the whole-row Charge carry got wrong

    func testCarriesLastNightsOwnVitals_evenWhenItsRecoveryIsNull() {
        // Last night recorded real HRV/RHR but its recovery came back null (BLE-only night, or scoring not
        // finished). The whole-row `lastScoredRecoveryDay` carry (gated on `recovery != nil`) would SKIP it
        // and reach back to the older scored day; this recovery-independent selector keeps last night's own
        // values. Combined with the call site's per-field today-first read, last night wins over the older
        // day — never the reverse.
        let days = [day("2026-06-16", recovery: 65, hrv: 44, rhr: 60, resp: 15.0),   // older, scored
                    day("2026-06-18", recovery: nil, hrv: 59, rhr: 50, resp: 13.2),  // last night: vitals, null recovery
                    day("2026-06-19")]   // today, no vitals yet
        let carried = DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(carried?.day, "2026-06-18",
                       "a night with vitals but null recovery must still be the vitals source, not skipped")
        XCTAssertEqual(carried?.avgHrv, 59, "keeps last night's OWN HRV, not the older scored day's 44")
        XCTAssertEqual(carried?.restingHr, 50)
    }

    func testSelectsRowWithAnyOneVital_notRequiringAllThree() {
        // A night that recorded only respiratory (no HRV/RHR) is still a valid source — the OR gate means
        // any single vital qualifies the row.
        let days = [day("2026-06-18", recovery: nil, hrv: nil, rhr: nil, resp: 14.4),
                    day("2026-06-19")]
        let carried = DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(carried?.day, "2026-06-18")
        XCTAssertEqual(carried?.respRateBpm, 14.4)
    }

    func testNil_whenNoPriorDayHasAnyVital() {
        // A history where no prior day recorded a single vital carries nothing — the tiles honestly show "–".
        let days = [day("2026-06-18", recovery: 70),   // scored, but no vitals fields
                    day("2026-06-19")]
        XCTAssertNil(DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19"))
    }

    // MARK: today-exclusion + future-day guard

    func testExcludesTodaysOwnRow_soItNeverEchoesToday() {
        // Today's row has partial vitals but the `< todayKey` bound excludes it, so the carry is the prior
        // day — the call site reads today's own field first anyway; the carry is strictly the fallback.
        let days = [day("2026-06-18", recovery: 72, hrv: 55, rhr: 52),
                    day("2026-06-19", hrv: 40)]   // today: a partial vital, still "today"
        let carried = DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(carried?.day, "2026-06-18", "the carry must be a strictly-prior day, never today's own row")
    }

    func testNeverSelectsAFutureDatedRow() {
        // A bad-clock strap can leave a future-dated row with vitals. The `< todayKey` bound must keep it
        // out so it can never surface as "last night's" vitals.
        let days = [day("2026-06-17", recovery: 60, hrv: 50, rhr: 54),
                    day("2026-06-18", recovery: 72, hrv: 58, rhr: 51),
                    day("2026-06-19"),                       // today, no vitals yet
                    day("2999-01-01", recovery: 80, hrv: 99, rhr: 40)]   // STRAY FUTURE row
        let carried = DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(carried?.day, "2026-06-18", "a future-dated row must never be carried as last night's vitals")
        XCTAssertEqual(carried?.avgHrv, 58)
    }

    func testNil_whenOnlyFutureRowsHaveVitals() {
        // If the only rows with vitals are future-dated, the carry honestly returns nil rather than reaching
        // forward in time.
        let days = [day("2026-06-19"),                              // today, no vitals
                    day("2999-01-01", recovery: 80, hrv: 99, rhr: 40)]
        XCTAssertNil(DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19"))
    }
}
