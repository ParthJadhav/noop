import XCTest
@testable import Strand

/// #977 (display half) — the freshness-gated Rest resolution that keeps the Today Rest hero HONEST for a
/// live 5.0 whose sleep never scores (no overnight gravity ⇒ no `sleep_performance` point ever written).
/// The display used to resolve Rest as "today's value, else the LATEST point in the whole series", which
/// pinned Rest to a weeks-old scored night while Charge (recovery) kept advancing — the frozen "93 since
/// forever" the reporter hit. `freshRestScore` gates the tail-fallback on recency: it still carries last
/// night's Rest before today scores, but once the last scored night is STALE it returns nil so the Rest
/// hero falls through to its No-Data / calibrating state instead of freezing on a stale number. Pure +
/// headless. Mirrors the Android `freshRestScoreTest`.
final class RestFreshnessTests: XCTestCase {

    // A fixed "today" so the recency window is deterministic regardless of the test host's wall clock.
    private let todayKey = "2026-06-19"

    func testTodaysOwnRow_wins_regardlessOfTail() {
        // Today's own scored Rest is shown even when a (fresher or staler) tail exists.
        XCTAssertEqual(
            TodayView.freshRestScore(todayValue: 71, lastDay: "2026-06-18", lastValue: 93,
                                     isTodaySelected: true, todayKey: todayKey),
            71)
        // …and even with a stale tail present.
        XCTAssertEqual(
            TodayView.freshRestScore(todayValue: 71, lastDay: "2026-06-07", lastValue: 93,
                                     isTodaySelected: true, todayKey: todayKey),
            71)
    }

    func testFreshTail_carries_whenNoTodayRow() {
        // No today row + a FRESH last-scored night (yesterday) → tail-fallback carries last night's Rest.
        // Unchanged (legitimate) morning-carry behaviour.
        XCTAssertEqual(
            TodayView.freshRestScore(todayValue: nil, lastDay: "2026-06-18", lastValue: 88,
                                     isTodaySelected: true, todayKey: todayKey),
            88)
    }

    func testStaleTail_doesNotCarry_readsNoData() {
        // No today row + a STALE last-scored night (12 days ago) → NO tail-fallback. This is the frozen-93
        // case: it now reads honestly as no data (nil), so the Rest hero shows its No-Data/calibrating state.
        XCTAssertNil(
            TodayView.freshRestScore(todayValue: nil, lastDay: "2026-06-07", lastValue: 93,
                                     isTodaySelected: true, todayKey: todayKey))
    }

    func testPastDaySelected_neverTailFalls() {
        // A navigated PAST day with no row shows nothing rather than borrowing the newest value.
        XCTAssertNil(
            TodayView.freshRestScore(todayValue: nil, lastDay: "2026-06-18", lastValue: 88,
                                     isTodaySelected: false, todayKey: todayKey))
    }

    func testNoTailAtAll_readsNoData() {
        // Cold start: no today row and no scored night anywhere → no number, no fabrication.
        XCTAssertNil(
            TodayView.freshRestScore(todayValue: nil, lastDay: nil, lastValue: nil,
                                     isTodaySelected: true, todayKey: todayKey))
    }
}
