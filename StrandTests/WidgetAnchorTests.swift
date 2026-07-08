import XCTest
import WhoopStore
@testable import Strand

/// #911: the SHARED anchor selector every off-dashboard surface (Home/Lock widget, watch snapshot AND
/// the iOS Live Activity) resolves the row it describes through, so a fourth surface can never drift its
/// own way around the day rollover again. Pins the SAME selection the Kotlin `widgetAnchorRow` asserts
/// (WidgetAnchorTest.kt) so the two platforms stay byte-for-byte in agreement: anchor on today's row when
/// scored, else carry the freshest STRICTLY-PRIOR scored day, with the #304 pre-04:00 carve-out and the
/// #547 future-day guard folded in.
final class WidgetAnchorTests: XCTestCase {

    /// A day row with an optional recovery + optional banked night, enough to exercise the resolver and
    /// the #304 carve-out (which keys off `totalSleepMin`).
    private func day(_ key: String, recovery: Double?, sleepMin: Double? = nil, strain: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: recovery,
                    strain: strain, exerciseCount: nil)
    }

    // (a) today scored -> today's own row.
    func testTodayScored_anchorsOnTodaysRow() {
        let days = [day("2026-06-18", recovery: 72), day("2026-06-19", recovery: 55, strain: 9)]
        let anchor = Repository.widgetAnchor(days: days, logicalKey: "2026-06-19", localKey: "2026-06-19")
        XCTAssertEqual(anchor?.day, "2026-06-19", "a scored today must be its own anchor")
        XCTAssertEqual(anchor?.recovery, 55)
    }

    // (b) today unscored, a prior scored day exists -> the freshest STRICTLY-PRIOR scored row.
    func testTodayUnscored_carriesFreshestPriorScoredDay() {
        let days = [day("2026-06-17", recovery: 60), day("2026-06-18", recovery: 72),
                    day("2026-06-19", recovery: nil)]   // today, banked but not scored yet
        let anchor = Repository.widgetAnchor(days: days, logicalKey: "2026-06-19", localKey: "2026-06-19")
        XCTAssertEqual(anchor?.day, "2026-06-18", "must carry the most recent SCORED prior day")
        XCTAssertEqual(anchor?.recovery, 72)
    }

    // (b, cont.) a today row that exists only with partial vitals (no recovery) must NOT be echoed as today.
    func testTodayUnscoredPartialRow_isNotEchoed() {
        let days = [day("2026-06-18", recovery: 72),
                    day("2026-06-19", recovery: nil)]   // today: exists but unscored
        let anchor = Repository.widgetAnchor(days: days, logicalKey: "2026-06-19", localKey: "2026-06-19")
        XCTAssertEqual(anchor?.day, "2026-06-18", "an unscored today must never surface as its own anchor")
    }

    // (c) #304 pre-04:00 carve-out: local calendar day differs from the logical day. When the local row
    // has a banked night, `resolveToday` prefers it; the anchor's carriedKey is then the LOCAL row's own
    // day, so a same-day later-scored logical row is NOT resurfaced past it.
    func testPre0400CarveOut_prefersLocalBankedRow_notASameDayLaterRow() {
        // Logical key still points at the 17th (small hours), but the just-finished night is banked under
        // the new LOCAL calendar day (the 18th) with a totalSleepMin. That local row IS today, even though
        // it has no recovery yet.
        let days = [day("2026-06-16", recovery: 60),
                    day("2026-06-17", recovery: 71),                 // yesterday, scored
                    day("2026-06-18", recovery: nil, sleepMin: 430)] // local banked night, unscored = today
        let anchor = Repository.widgetAnchor(days: days, logicalKey: "2026-06-17", localKey: "2026-06-18")
        // today (the 18th local row) is unscored, so the carry-over kicks in. carriedKey == "2026-06-18"
        // (the local row's own day), so the freshest STRICTLY-PRIOR scored day is the 17th, NOT re-echoed
        // as the local row and NOT the 16th.
        XCTAssertEqual(anchor?.day, "2026-06-17",
                       "carriedKey is the local banked row's day; the prior scored day carries over")
        XCTAssertEqual(anchor?.recovery, 71)
    }

    func testPre0400CarveOut_localBankedRowScored_isItsOwnAnchor() {
        // Same carve-out, but the local banked night is already scored -> it is its own anchor, not a carry.
        let days = [day("2026-06-17", recovery: 71),
                    day("2026-06-18", recovery: 66, sleepMin: 430)]
        let anchor = Repository.widgetAnchor(days: days, logicalKey: "2026-06-17", localKey: "2026-06-18")
        XCTAssertEqual(anchor?.day, "2026-06-18", "a scored local banked row is its own anchor")
        XCTAssertEqual(anchor?.recovery, 66)
    }

    // (d) a future-dated row (#547) is never selected as the anchor.
    func testNeverAnchorsAFutureDatedRow() {
        let days = [day("2026-06-17", recovery: 60), day("2026-06-18", recovery: 72),
                    day("2026-06-19", recovery: nil),    // today, unscored
                    day("2026-07-12", recovery: 80)]     // STRAY future row
        let anchor = Repository.widgetAnchor(days: days, logicalKey: "2026-06-19", localKey: "2026-06-19")
        XCTAssertEqual(anchor?.day, "2026-06-18", "a future-dated row must never be the anchor")
        XCTAssertEqual(anchor?.recovery, 72)
    }

    func testFutureOnlyBesidesToday_returnsNil() {
        // If the ONLY scored rows are future-dated, the anchor honestly returns nil (blank widget) rather
        // than reaching forward in time.
        let days = [day("2026-06-19", recovery: nil),    // today, unscored
                    day("2026-07-12", recovery: 80)]     // future-only
        XCTAssertNil(Repository.widgetAnchor(days: days, logicalKey: "2026-06-19", localKey: "2026-06-19"))
    }

    // (e) no data -> nil (blank widget, no crash).
    func testNoData_returnsNil() {
        XCTAssertNil(Repository.widgetAnchor(days: [], logicalKey: "2026-06-19", localKey: "2026-06-19"))
    }

    func testNoPriorEverScored_returnsNil() {
        let days = [day("2026-06-18", recovery: nil), day("2026-06-19", recovery: nil)]
        XCTAssertNil(Repository.widgetAnchor(days: days, logicalKey: "2026-06-19", localKey: "2026-06-19"))
    }
}
