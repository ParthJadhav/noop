import XCTest
@testable import Strand

/// #860 item 1 - the launch day-landing policy. A reporter on v7.6.0 saw a fresh launch / app update land
/// the Today screen on an OLD day instead of today: the retired #605/#739 "auto-land on the most recent day
/// with data" fired when today had no data yet, and for a calibrating user whose newest data was a few days
/// back it stranded them there, overriding the snap-to-today. `launchDayOffset` encodes the fixed policy as
/// one pure decision so it can't drift from the Kotlin twin or from the view: a FRESH launch always returns 0
/// (today), even when the only data is N days back; an in-session call returns the saved offset unchanged so
/// day memory (#739/#614) is never regressed.
final class TodayLaunchLandTests: XCTestCase {

    // MARK: - The reported bug

    func testFreshLaunchLandsOnTodayEvenWithOnlyOldData() {
        // The reporter's case: a fresh process, today has no data yet, and the only banked data is 5 days
        // back (a calibrating user). The retired auto-land would have returned 5 and stranded them on that
        // old day. The policy now returns 0 (today), unconditionally.
        XCTAssertEqual(
            TodayView.launchDayOffset(isFreshLaunch: true,
                                      savedOffset: 0,
                                      hasTodayData: false,
                                      latestDataDayBack: 5),
            0)
    }

    // MARK: - Fresh launch always lands on today

    func testFreshLaunchWithTodayDataLandsOnToday() {
        XCTAssertEqual(
            TodayView.launchDayOffset(isFreshLaunch: true,
                                      savedOffset: 0,
                                      hasTodayData: true,
                                      latestDataDayBack: 0),
            0)
    }

    func testFreshLaunchIgnoresAnyStaleSavedOffset() {
        // Even if a saved offset somehow rides a restore, a fresh launch overrides it back to today.
        XCTAssertEqual(
            TodayView.launchDayOffset(isFreshLaunch: true,
                                      savedOffset: 7,
                                      hasTodayData: false,
                                      latestDataDayBack: 7),
            0)
    }

    // MARK: - In-session preserves the navigated day (#739/#614 - no regression)

    func testInSessionPreservesNavigatedDay() {
        // Tabbing away to an old day (offset 3) and coming back within the SAME process must keep that day.
        XCTAssertEqual(
            TodayView.launchDayOffset(isFreshLaunch: false,
                                      savedOffset: 3,
                                      hasTodayData: false,
                                      latestDataDayBack: 5),
            3)
    }

    func testInSessionOnTodayStaysOnToday() {
        XCTAssertEqual(
            TodayView.launchDayOffset(isFreshLaunch: false,
                                      savedOffset: 0,
                                      hasTodayData: true,
                                      latestDataDayBack: 0),
            0)
    }
}
