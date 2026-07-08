import XCTest
@testable import StrandAnalytics

/// #940: the sleep-time editor accepted an impossible bed time. Rolling the bed TIME back across
/// midnight (01:06 -> 23:00) kept the calendar date, so the "corrected" bed landed on the coming
/// evening: a future-dated night the Sleep tab could not render. These pin the three pure guard
/// rules (Android twin: SleepEditGuardTest.kt).
final class SleepEditGuardTests: XCTestCase {

    /// Fixed UTC calendar so day math is deterministic regardless of the runner's zone.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: - Rule 1: cross-midnight bed auto-correct

    /// THE #940 SHAPE: night tracked late (bed 01:06, wake 05:00 on 2 Jul), user rolls the bed TIME
    /// back to 23:00 at 05:03 the same morning. The picker kept the date on 2 Jul, so the candidate
    /// is tonight (future, and past the wake). The guard snaps it to 1 Jul 23:00: the evening the
    /// user meant.
    func testCrossMidnightRollBackDecrementsDate() {
        let previous = date(2026, 7, 2, 1, 6)      // seeded effective onset
        let candidate = date(2026, 7, 2, 23, 0)    // rolled back to 23:00, date unchanged
        let wake = date(2026, 7, 2, 5, 0)
        let now = date(2026, 7, 2, 5, 3)
        let corrected = SleepEditGuard.autoCorrectedBed(
            previousBed: previous, candidateBed: candidate, originalWake: wake, now: now, calendar: cal)
        XCTAssertEqual(corrected, date(2026, 7, 1, 23, 0))
    }

    /// Same roll made in the EVENING (now 23:30, so 23:00 today is not future) still decrements:
    /// the candidate sits at/after the night's wake, which is impossible for that night's bed.
    func testPastWakeButNotFutureStillDecrements() {
        let previous = date(2026, 7, 2, 1, 6)
        let candidate = date(2026, 7, 2, 23, 0)
        let wake = date(2026, 7, 2, 5, 0)
        let now = date(2026, 7, 2, 23, 30)
        let corrected = SleepEditGuard.autoCorrectedBed(
            previousBed: previous, candidateBed: candidate, originalWake: wake, now: now, calendar: cal)
        XCTAssertEqual(corrected, date(2026, 7, 1, 23, 0))
    }

    /// MOVE-LATER (the finding's missing case): a user drags a session's bed LATER, past its own wake,
    /// on the SAME day (nap 14:00-15:00 -> bed 16:00 today, wake 15:00 today). The candidate is at/after
    /// the wake but in the PAST, so the old rule shoved it back a full day into a ~23h wrong-day window.
    /// Decrementing here would form an implausible 23h night, so the candidate must be left VERBATIM.
    func testMoveLaterPastWakeIsNotDecremented() {
        let previous = date(2026, 7, 2, 14, 0)     // nap start being edited
        let candidate = date(2026, 7, 2, 16, 0)    // rolled LATER, still same day, after the 15:00 wake
        let wake = date(2026, 7, 2, 15, 0)
        let now = date(2026, 7, 2, 20, 0)          // evening: 16:00 today is in the past, not future
        let corrected = SleepEditGuard.autoCorrectedBed(
            previousBed: previous, candidateBed: candidate, originalWake: wake, now: now, calendar: cal)
        XCTAssertEqual(corrected, candidate, "a plausible move-later must not be shoved back a day")
    }

    /// A normal correction (01:06 -> 00:30, still before the wake, in the past) is untouched.
    func testSaneEditIsUntouched() {
        let previous = date(2026, 7, 2, 1, 6)
        let candidate = date(2026, 7, 2, 0, 30)
        let wake = date(2026, 7, 2, 5, 0)
        let now = date(2026, 7, 2, 6, 45)
        let corrected = SleepEditGuard.autoCorrectedBed(
            previousBed: previous, candidateBed: candidate, originalWake: wake, now: now, calendar: cal)
        XCTAssertEqual(corrected, candidate)
    }

    /// A DELIBERATE date change (candidate on a different calendar day from the previous value) is
    /// always respected verbatim: the rule only rescues time-only rolls.
    func testDeliberateDateChangeIsRespected() {
        let previous = date(2026, 7, 2, 1, 6)
        let candidate = date(2026, 6, 28, 6, 0)    // user moved the date wheel back four days
        let wake = date(2026, 7, 2, 5, 0)
        let now = date(2026, 7, 2, 6, 45)
        let corrected = SleepEditGuard.autoCorrectedBed(
            previousBed: previous, candidateBed: candidate, originalWake: wake, now: now, calendar: cal)
        XCTAssertEqual(corrected, candidate)
    }

    /// Add-a-nap (no originalWake): only the FUTURE test applies. A nap start after the night's
    /// wake is normal and stays; a future nap start snaps back a day.
    func testNapStartOnlyFutureRuleApplies() {
        let previous = date(2026, 7, 2, 6, 0)      // seed anchor: an hour after wake
        let now = date(2026, 7, 2, 18, 0)
        // 14:00 today: after the wake but in the past -> untouched.
        let pastNap = SleepEditGuard.autoCorrectedBed(
            previousBed: previous, candidateBed: date(2026, 7, 2, 14, 0),
            originalWake: nil, now: now, calendar: cal)
        XCTAssertEqual(pastNap, date(2026, 7, 2, 14, 0))
        // 22:00 today: in the future -> the user means a nap that already happened; snap back a day.
        let futureNap = SleepEditGuard.autoCorrectedBed(
            previousBed: previous, candidateBed: date(2026, 7, 2, 22, 0),
            originalWake: nil, now: now, calendar: cal)
        XCTAssertEqual(futureNap, date(2026, 7, 1, 22, 0))
    }

    /// If decrementing a day would STILL be in the future (unreachable from a real time-only roll,
    /// but the rule must not loop or overshoot) the candidate is returned unchanged; the disjoint
    /// confirm and the persistence clamp are the layers behind it.
    func testDecrementThatStaysFutureIsNotApplied() {
        let previous = date(2026, 7, 5, 1, 0)
        let candidate = date(2026, 7, 5, 23, 0)
        let now = date(2026, 7, 2, 6, 45)
        let corrected = SleepEditGuard.autoCorrectedBed(
            previousBed: previous, candidateBed: candidate, originalWake: nil, now: now, calendar: cal)
        XCTAssertEqual(corrected, candidate)
    }

    // MARK: - Rule 2: disjoint-from-coverage detection

    func testOverlappingWindowIsNotDisjoint() {
        // Coverage 01:06-05:00; corrected 23:00 (prev day) - 05:00 overlaps it.
        XCTAssertFalse(SleepEditGuard.isDisjoint(newStart: 1000, newEnd: 5000,
                                                 coverageStart: 2000, coverageEnd: 5000))
        // Window fully inside coverage.
        XCTAssertFalse(SleepEditGuard.isDisjoint(newStart: 2500, newEnd: 3000,
                                                 coverageStart: 2000, coverageEnd: 5000))
    }

    func testFullyFutureWindowIsDisjoint() {
        // THE #940 SHAPE: coverage 01:06-05:00 today; corrected window tonight 23:00 -> 05:00 tomorrow.
        XCTAssertTrue(SleepEditGuard.isDisjoint(newStart: 80_000, newEnd: 100_000,
                                                coverageStart: 2_000, coverageEnd: 18_000))
    }

    func testFullyPastWindowIsDisjoint() {
        XCTAssertTrue(SleepEditGuard.isDisjoint(newStart: 0, newEnd: 1_000,
                                                coverageStart: 2_000, coverageEnd: 18_000))
    }

    /// Touching endpoints share no samples: still disjoint (half-open window semantics).
    func testTouchingWindowIsDisjoint() {
        XCTAssertTrue(SleepEditGuard.isDisjoint(newStart: 18_000, newEnd: 20_000,
                                                coverageStart: 2_000, coverageEnd: 18_000))
        XCTAssertTrue(SleepEditGuard.isDisjoint(newStart: 0, newEnd: 2_000,
                                                coverageStart: 2_000, coverageEnd: 18_000))
    }

    // MARK: - Rule 3: persistence clamp

    func testPastWindowPersistsUnchanged() {
        let w = SleepEditGuard.clampedEditWindow(start: 1_000, end: 5_000, now: 10_000)
        XCTAssertEqual(w?.start, 1_000)
        XCTAssertEqual(w?.end, 5_000)
    }

    func testFutureEndIsCappedAtNowPlusSlack() {
        let w = SleepEditGuard.clampedEditWindow(start: 1_000, end: 50_000, now: 10_000, slackSec: 300)
        XCTAssertEqual(w?.start, 1_000)
        XCTAssertEqual(w?.end, 10_300)
    }

    func testFullyFutureWindowIsRefused() {
        // THE #940 phantom: both ends after now. Capping the end lands at/below the start -> nil.
        XCTAssertNil(SleepEditGuard.clampedEditWindow(start: 80_000, end: 100_000, now: 10_000))
    }

    func testInvertedWindowIsRefused() {
        XCTAssertNil(SleepEditGuard.clampedEditWindow(start: 5_000, end: 4_000, now: 10_000))
        XCTAssertNil(SleepEditGuard.clampedEditWindow(start: 5_000, end: 5_000, now: 10_000))
    }
}
