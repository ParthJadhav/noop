import XCTest
@testable import Strand

/// Per-weekday smart-alarm scheduling (PR #539, @hkuehl): the alarm only fires on selected weekdays.
/// Covers the pure date math (`AppModel.nextSmartAlarmDate`) and the picker's selection rules
/// (`SmartAlarmView.alarmToggledWeekday` / `alarmWeekdayIsSelected` / `alarmWeekdaySummary`).
///
/// The picker rules moved from AutomationsView to SmartAlarmView in #766 (the strap wake-alarm UI was
/// consolidated onto the dedicated Alarms screen); the helpers gained an `alarm` prefix there.
///
/// Calendar weekday numbers: 1 = Sun … 7 = Sat. An empty set means "every day" (backward compatible).
final class SmartAlarmWeekdayTests: XCTestCase {

    /// Fixed UTC calendar so the math is deterministic regardless of the test machine's locale/zone.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-06-17 is a Wednesday (weekday 4). Build a reference "now" at a given hour:minute UTC.
    private func wed(_ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: hour, minute: minute))!
    }

    private func weekday(of date: Date) -> Int { cal.component(.weekday, from: date) }

    // MARK: nextSmartAlarmDate

    func testEveryDay_emptySet_picksTodayWhenTimeStillAhead() {
        // now = Wed 06:00, wake at 07:00 → same day, 07:00.
        let next = AppModel.nextSmartAlarmDate(minutes: 7 * 60, weekdays: [], from: wed(6, 0), calendar: cal)
        XCTAssertEqual(next, wed(7, 0))
    }

    func testEveryDay_emptySet_rollsToTomorrowWhenTimePassed() {
        // now = Wed 08:00, wake at 07:00 → tomorrow (Thu) 07:00.
        let next = AppModel.nextSmartAlarmDate(minutes: 7 * 60, weekdays: [], from: wed(8, 0), calendar: cal)
        XCTAssertEqual(next, cal.date(byAdding: .day, value: 1, to: wed(7, 0)))
    }

    func testSingleWeekday_today_beforeTime_firesToday() {
        // now = Wed 06:00, only Wednesdays (weekday 4) selected → today 07:00.
        let next = AppModel.nextSmartAlarmDate(minutes: 7 * 60, weekdays: [4], from: wed(6, 0), calendar: cal)
        XCTAssertEqual(next, wed(7, 0))
        XCTAssertEqual(weekday(of: next!), 4)
    }

    func testSingleWeekday_today_afterTime_firesNextWeek() {
        // now = Wed 08:00, only Wednesdays → next Wednesday 07:00 (7 days later).
        let next = AppModel.nextSmartAlarmDate(minutes: 7 * 60, weekdays: [4], from: wed(8, 0), calendar: cal)
        XCTAssertEqual(next, cal.date(byAdding: .day, value: 7, to: wed(7, 0)))
        XCTAssertEqual(weekday(of: next!), 4)
    }

    func testWeekendsOnly_fromWednesday_firesSaturday() {
        // now = Wed 06:00, weekends [Sun=1, Sat=7] → next Saturday (3 days later) 07:00.
        let next = AppModel.nextSmartAlarmDate(minutes: 7 * 60, weekdays: [1, 7], from: wed(6, 0), calendar: cal)
        XCTAssertEqual(weekday(of: next!), 7, "Saturday")
        XCTAssertEqual(next, cal.date(byAdding: .day, value: 3, to: wed(7, 0)))
    }

    func testWeekdaysOnly_fromSaturday_firesMonday() {
        // Reference Saturday 2026-06-20, weekdays Mon–Fri [2…6] → Monday (2 days later).
        let sat = cal.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 6, minute: 0))!
        let next = AppModel.nextSmartAlarmDate(minutes: 7 * 60, weekdays: Set(2...6), from: sat, calendar: cal)
        XCTAssertEqual(weekday(of: next!), 2, "Monday")
    }

    func testInvalidWeekdayNumbers_areIgnored_andFallBackToNil() {
        // A set with only out-of-range days (0, 8, 99) is treated as no valid days → nil.
        let next = AppModel.nextSmartAlarmDate(minutes: 7 * 60, weekdays: [0, 8, 99], from: wed(6, 0), calendar: cal)
        XCTAssertNil(next)
    }

    func testInvalidMixedWithValid_keepsOnlyValid() {
        // [99, 4] → only Wednesday (4) is honoured.
        let next = AppModel.nextSmartAlarmDate(minutes: 7 * 60, weekdays: [99, 4], from: wed(6, 0), calendar: cal)
        XCTAssertEqual(weekday(of: next!), 4)
    }

    func testFireIsAlwaysStrictlyInTheFuture() {
        // Exactly at the wake minute → must skip to the next occurrence, never return "now".
        let next = AppModel.nextSmartAlarmDate(minutes: 7 * 60, weekdays: [], from: wed(7, 0), calendar: cal)
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, wed(7, 0))
    }

    // MARK: Picker selection rules

    func testWeekdayIsSelected_emptyMeansEveryDay() {
        for dow in 1...7 { XCTAssertTrue(SmartAlarmView.alarmWeekdayIsSelected(dow, in: [])) }
    }

    func testToggle_fromEveryDay_deselectsJustOne() {
        // Empty (every day) → tap Wed (4) off → the other six explicit.
        let result = SmartAlarmView.alarmToggledWeekday(4, in: [])
        XCTAssertEqual(result, Set([1, 2, 3, 5, 6, 7]))
    }

    func testToggle_reselectingSeventh_collapsesBackToEveryDay() {
        // Six selected, add the last one → canonical empty "every day".
        let result = SmartAlarmView.alarmToggledWeekday(4, in: Set([1, 2, 3, 5, 6, 7]))
        XCTAssertTrue(result.isEmpty, "all seven selected collapses to the empty every-day set")
    }

    func testToggle_addAndRemoveWithinExplicitSet() {
        XCTAssertEqual(SmartAlarmView.alarmToggledWeekday(3, in: [2]), Set([2, 3]))
        XCTAssertEqual(SmartAlarmView.alarmToggledWeekday(2, in: [2, 3]), Set([3]))
    }

    func testSummary_labels() {
        XCTAssertEqual(SmartAlarmView.alarmWeekdaySummary([]), "Every day")
        XCTAssertEqual(SmartAlarmView.alarmWeekdaySummary(Set(1...7)), "Every day")
        XCTAssertEqual(SmartAlarmView.alarmWeekdaySummary(Set(2...6)), "Weekdays")
        XCTAssertEqual(SmartAlarmView.alarmWeekdaySummary(Set([1, 7])), "Weekends")
        // Mixed set lists Monday-first short names.
        XCTAssertEqual(SmartAlarmView.alarmWeekdaySummary(Set([2, 4])), "Mon, Wed")
    }
}
