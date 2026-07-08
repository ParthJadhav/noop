import XCTest
@testable import Strand

/// #817 - the day-nav swipe / chevron clamp. The same pure bounds back the swipe gesture, the prev/next
/// chevrons and the date jump, so they are pinned here: a swipe or tap can never reach a FUTURE day
/// (offset < 0) or a day OLDER than the earliest banked day (offset > maxOffset). A wrong sign or a
/// drifted bound would let the user strand on an empty day, so the contract is locked by these tests.
final class TodayDayNavClampTests: XCTestCase {

    // MARK: - clampedDayOffset

    func testStepOlderIncrementsOffsetWithinBounds() {
        // From today (0), a left-swipe / older step (+1) reaches yesterday (1).
        XCTAssertEqual(TodayView.clampedDayOffset(current: 0, delta: 1, maxOffset: 30), 1)
    }

    func testStepNewerDecrementsOffset() {
        // From two days back, a right-swipe / newer step (-1) reaches one day back.
        XCTAssertEqual(TodayView.clampedDayOffset(current: 2, delta: -1, maxOffset: 30), 1)
    }

    func testCannotGoNewerThanToday() {
        // Already on today (0); a newer step (-1) is clamped at 0 - no future day.
        XCTAssertEqual(TodayView.clampedDayOffset(current: 0, delta: -1, maxOffset: 30), 0)
    }

    func testCannotGoOlderThanEarliestDay() {
        // On the earliest day (offset == maxOffset); an older step (+1) is clamped at maxOffset.
        XCTAssertEqual(TodayView.clampedDayOffset(current: 5, delta: 1, maxOffset: 5), 5)
    }

    func testZeroMaxOffsetPinsToToday() {
        // No history yet (maxOffset 0): neither direction leaves today.
        XCTAssertEqual(TodayView.clampedDayOffset(current: 0, delta: 1, maxOffset: 0), 0)
        XCTAssertEqual(TodayView.clampedDayOffset(current: 0, delta: -1, maxOffset: 0), 0)
    }

    func testNegativeMaxOffsetTreatedAsZero() {
        // A defensive negative bound collapses to "today only" rather than inverting the clamp.
        XCTAssertEqual(TodayView.clampedDayOffset(current: 0, delta: 1, maxOffset: -3), 0)
    }

    // MARK: - maxDayOffset

    func testMaxDayOffsetCountsWholeDaysBackToEarliest() {
        // Earliest banked day is 4 days before today -> 4 reachable past days.
        XCTAssertEqual(TodayView.maxDayOffset(earliestDayKey: "2026-06-24", todayKey: "2026-06-28"), 4)
    }

    func testMaxDayOffsetZeroWhenEarliestIsToday() {
        XCTAssertEqual(TodayView.maxDayOffset(earliestDayKey: "2026-06-28", todayKey: "2026-06-28"), 0)
    }

    func testMaxDayOffsetZeroWhenNoData() {
        XCTAssertEqual(TodayView.maxDayOffset(earliestDayKey: nil, todayKey: "2026-06-28"), 0)
    }

    func testMaxDayOffsetZeroForUnparseableKey() {
        XCTAssertEqual(TodayView.maxDayOffset(earliestDayKey: "not-a-date", todayKey: "2026-06-28"), 0)
    }

    func testMaxDayOffsetClampsFutureEarliestToZero() {
        // A stray future-dated earliest key must not yield a negative reach.
        XCTAssertEqual(TodayView.maxDayOffset(earliestDayKey: "2026-07-01", todayKey: "2026-06-28"), 0)
    }

    // MARK: - pickedDayOffset (#16 - 00:00-04:00 rollover)

    /// Picking the logical day itself is always offset 0, whatever the wall clock says.
    func testPickedDayOffsetSameLogicalDayIsZero() {
        let cal = Calendar.current
        let logical = cal.date(from: DateComponents(year: 2026, month: 6, day: 28))!
        XCTAssertEqual(TodayView.pickedDayOffset(pickedDate: logical, anchorLogicalDay: logical), 0)
    }

    /// THE rollover case: at 02:00 on the 29th the logical day is still the 28th. Picking the 28th must be
    /// offset 0 (today), and picking the 29th - the calendar day that raw Date() would have used as the
    /// anchor - must clamp to 0, never a negative/future offset.
    func testPickedDayOffsetInRolloverWindowAnchorsToLogicalDay() {
        let cal = Calendar.current
        let logical = cal.date(from: DateComponents(year: 2026, month: 6, day: 28))!          // logical "today"
        let calendarDay = cal.date(from: DateComponents(year: 2026, month: 6, day: 29))!      // wall-clock day at 02:00
        // The logical day reads as today.
        XCTAssertEqual(TodayView.pickedDayOffset(pickedDate: logical, anchorLogicalDay: logical), 0)
        // The wall-clock-ahead day clamps to today rather than going negative.
        XCTAssertEqual(TodayView.pickedDayOffset(pickedDate: calendarDay, anchorLogicalDay: logical), 0)
    }

    /// A genuine past pick counts whole days back from the logical anchor.
    func testPickedDayOffsetCountsWholeDaysBack() {
        let cal = Calendar.current
        let logical = cal.date(from: DateComponents(year: 2026, month: 6, day: 28))!
        let picked = cal.date(from: DateComponents(year: 2026, month: 6, day: 24))!
        XCTAssertEqual(TodayView.pickedDayOffset(pickedDate: picked, anchorLogicalDay: logical), 4)
    }
}
