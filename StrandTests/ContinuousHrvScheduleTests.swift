import XCTest
@testable import Strand

/// Pins the #927 Continuous HRV "overnight only" window predicate (`ContinuousHrvSchedule`).
///
/// The window reuses the app's quiet-hours convention byte-for-byte: minutes since LOCAL midnight,
/// inclusive start, exclusive end, and the window may wrap across midnight (22:00 → 07:00 by default).
/// The predicate takes the wall-clock minute IN (no date, no epoch), exactly like quiet hours, which is
/// what makes it DST-agnostic: a DST jump moves the wall clock, the window definition never changes, and
/// there is no date arithmetic to disagree with the user's clock. Pure value type, no seams needed.
final class ContinuousHrvScheduleTests: XCTestCase {

    /// The quiet-hours defaults the schedule reuses (22:00 → 07:00).
    private let start = ContinuousHrvSchedule.defaultStartMinutes   // 1320
    private let end = ContinuousHrvSchedule.defaultEndMinutes       // 420

    // MARK: Mode composition (no migration)

    /// Feature off ⇒ never wanted, at any time of day, regardless of the overnight flag. (The composed
    /// OFF mode: both booleans off, or overnight on with the base toggle off.)
    func testOffModeNeverWants() {
        for minute in [0, 6 * 60, 12 * 60, 22 * 60, 1439] {
            XCTAssertFalse(ContinuousHrvSchedule.streamWanted(
                continuousHrv: false, overnightOnly: false,
                minuteOfDay: minute, startMin: start, endMin: end))
            XCTAssertFalse(ContinuousHrvSchedule.streamWanted(
                continuousHrv: false, overnightOnly: true,
                minuteOfDay: minute, startMin: start, endMin: end))
        }
    }

    /// ALWAYS mode: continuous on + overnight off ⇒ wanted 24/7. This is what every EXISTING Continuous
    /// HRV user reads with no migration (the new overnight key simply defaults to false), so #927 changes
    /// nothing for them.
    func testAlwaysModeWantsAllDay() {
        for minute in [0, 3 * 60, 6 * 60 + 59, 7 * 60, 12 * 60, 21 * 60 + 59, 22 * 60, 1439] {
            XCTAssertTrue(ContinuousHrvSchedule.streamWanted(
                continuousHrv: true, overnightOnly: false,
                minuteOfDay: minute, startMin: start, endMin: end))
        }
    }

    /// OVERNIGHT mode: wanted inside the window, not outside; the daytime half of the day disarms.
    func testOvernightModeGatesOnWindow() {
        XCTAssertTrue(ContinuousHrvSchedule.streamWanted(
            continuousHrv: true, overnightOnly: true,
            minuteOfDay: 23 * 60, startMin: start, endMin: end))     // 23:00: inside
        XCTAssertFalse(ContinuousHrvSchedule.streamWanted(
            continuousHrv: true, overnightOnly: true,
            minuteOfDay: 12 * 60, startMin: start, endMin: end))     // noon: outside
    }

    // MARK: Window boundaries (quiet-hours semantics, byte-for-byte)

    /// Inclusive start: 22:00 exactly is INSIDE; 21:59 is outside. Matches quiet hours (`now >= start`).
    func testStartBoundaryInclusive() {
        XCTAssertTrue(ContinuousHrvSchedule.windowContains(22 * 60, startMin: start, endMin: end))
        XCTAssertFalse(ContinuousHrvSchedule.windowContains(21 * 60 + 59, startMin: start, endMin: end))
    }

    /// Exclusive end: 07:00 exactly is OUTSIDE; 06:59 is inside. Matches quiet hours (`now < end`).
    func testEndBoundaryExclusive() {
        XCTAssertFalse(ContinuousHrvSchedule.windowContains(7 * 60, startMin: start, endMin: end))
        XCTAssertTrue(ContinuousHrvSchedule.windowContains(6 * 60 + 59, startMin: start, endMin: end))
    }

    /// The default window wraps midnight: late evening, midnight itself and the small hours are all
    /// inside; midday is outside. (start > end ⇒ `minute >= start || minute < end`.)
    func testWrapAcrossMidnight() {
        XCTAssertTrue(ContinuousHrvSchedule.windowContains(23 * 60 + 59, startMin: start, endMin: end))
        XCTAssertTrue(ContinuousHrvSchedule.windowContains(0, startMin: start, endMin: end))
        XCTAssertTrue(ContinuousHrvSchedule.windowContains(3 * 60, startMin: start, endMin: end))
        XCTAssertFalse(ContinuousHrvSchedule.windowContains(12 * 60, startMin: start, endMin: end))
        XCTAssertFalse(ContinuousHrvSchedule.windowContains(15 * 60, startMin: start, endMin: end))
    }

    /// A non-wrapping window (start <= end) is the plain [start, end) interval: someone who sets their
    /// quiet hours to 01:00 → 05:00 gets exactly that.
    func testNonWrappingWindow() {
        let s = 1 * 60, e = 5 * 60
        XCTAssertFalse(ContinuousHrvSchedule.windowContains(0, startMin: s, endMin: e))
        XCTAssertFalse(ContinuousHrvSchedule.windowContains(59, startMin: s, endMin: e))
        XCTAssertTrue(ContinuousHrvSchedule.windowContains(60, startMin: s, endMin: e))       // 01:00 in
        XCTAssertTrue(ContinuousHrvSchedule.windowContains(4 * 60 + 59, startMin: s, endMin: e))
        XCTAssertFalse(ContinuousHrvSchedule.windowContains(5 * 60, startMin: s, endMin: e))  // 05:00 out
        XCTAssertFalse(ContinuousHrvSchedule.windowContains(12 * 60, startMin: s, endMin: e))
    }

    /// start == end is an EMPTY window (the [start, start) convention), never "all day"; byte-for-byte
    /// what the quiet-hours membership does with equal times.
    func testDegenerateEqualWindowIsEmpty() {
        let s = 8 * 60
        for minute in [0, s - 1, s, s + 1, 23 * 60] {
            XCTAssertFalse(ContinuousHrvSchedule.windowContains(minute, startMin: s, endMin: s))
        }
    }

    /// The extremes of the minute-of-day domain behave: minute 0 (midnight) and 1439 (23:59) resolve
    /// against the wrapped default window without any modular surprises.
    func testMinuteDomainExtremes() {
        XCTAssertTrue(ContinuousHrvSchedule.windowContains(0, startMin: start, endMin: end))      // 00:00 in
        XCTAssertTrue(ContinuousHrvSchedule.windowContains(1439, startMin: start, endMin: end))   // 23:59 in
        // And against a daytime window both extremes are out.
        XCTAssertFalse(ContinuousHrvSchedule.windowContains(0, startMin: 9 * 60, endMin: 17 * 60))
        XCTAssertFalse(ContinuousHrvSchedule.windowContains(1439, startMin: 9 * 60, endMin: 17 * 60))
    }
}
