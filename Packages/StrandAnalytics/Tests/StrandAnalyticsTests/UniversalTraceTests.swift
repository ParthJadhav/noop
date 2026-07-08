import XCTest
@testable import StrandAnalytics

/// The universal clock-drift line that rides EVERY export (RTC cluster #531/#767/#804/#812). Pins the
/// format and the FUTURE-DATE flag so the export parser and the Kotlin twin can never silently drift.
final class UniversalTraceTests: XCTestCase {

    // 2026-06-28 00:00:00 UTC
    private let wall = 1782604800

    func testClockOkLineFormat() {
        let line = UniversalTrace.clockDriftLine(newestUnix: wall - 60, wallNowUnix: wall,
                                                 oldestUnix: wall - 86_400 * 3, firmwareLayout: 25)
        XCTAssertTrue(line.hasPrefix("strapClock newest="))
        XCTAssertTrue(line.contains("wall="))
        XCTAssertTrue(line.contains("newestVsWall=-60s"))
        XCTAssertTrue(line.contains("spanDays=3"))
        XCTAssertTrue(line.contains("firmware=v25"))
        XCTAssertTrue(line.hasSuffix("clockOk"))
        XCTAssertFalse(line.contains("\u{2014}"), "no em-dashes")
    }

    func testFutureDatedStrapIsFlagged() {
        // Newest record is an hour ahead of wall: a wandering / un-clocked RTC, the #767 tell.
        let line = UniversalTrace.clockDriftLine(newestUnix: wall + 3_600, wallNowUnix: wall)
        XCTAssertTrue(line.contains("newestVsWall=+3600s"))
        XCTAssertTrue(line.contains("FUTURE-DATED"))
        XCTAssertFalse(line.contains("clockOk"))
    }

    func testWithinToleranceIsNotFlagged() {
        // A minute ahead is normal RTC skew, under the default 120s tolerance.
        let line = UniversalTrace.clockDriftLine(newestUnix: wall + 60, wallNowUnix: wall)
        XCTAssertTrue(line.contains("clockOk"))
        XCTAssertFalse(line.contains("FUTURE-DATED"))
    }

    func testUnknownFirmwareWhenNotObserved() {
        let line = UniversalTrace.clockDriftLine(newestUnix: wall, wallNowUnix: wall)
        XCTAssertTrue(line.contains("firmware=unknown"))
    }

    func testOldestOmittedWhenNotBelowNewest() {
        // A half/short range reply (oldest >= newest, or nil) omits the span entirely.
        let line = UniversalTrace.clockDriftLine(newestUnix: wall, wallNowUnix: wall, oldestUnix: wall + 10)
        XCTAssertFalse(line.contains("oldest="))
        XCTAssertFalse(line.contains("spanDays="))
    }

    // #990: a newest banked record 363 DAYS behind wall used to read "clockOk" - the false all-clear
    // that hid the reporter's real clock fault. Beyond +-48h it must read as a clock warning.
    func testFarBehindDriftIsAClockWarningNotOk() {
        let line = UniversalTrace.clockDriftLine(newestUnix: wall - 363 * 86_400, wallNowUnix: wall)
        XCTAssertTrue(line.contains("CLOCK-WARNING"), line)
        XCTAssertTrue(line.contains("363d behind wall"), line)
        XCTAssertFalse(line.contains("clockOk"), line)
    }

    func testBehindWithinTwoDaysStaysOk() {
        // 47h behind = an unworn strap, not a clock fault: still clockOk.
        let line = UniversalTrace.clockDriftLine(newestUnix: wall - 47 * 3_600, wallNowUnix: wall)
        XCTAssertTrue(line.hasSuffix("clockOk"), line)
    }

    // #987: an epoch-era newest (strap RTC never set, reads ~1970/71) is its own named fault, more
    // specific than the generic behind warning, with the fix (charge + reconnect) in the line.
    func testEpochEraNewestReadsRtcEpoch() {
        let line = UniversalTrace.clockDriftLine(newestUnix: 40_000_000, wallNowUnix: wall)  // 1971-04
        XCTAssertTrue(line.contains("RTC-EPOCH"), line)
        XCTAssertTrue(line.contains("1970/71"), line)
        XCTAssertFalse(line.contains("clockOk"), line)
    }
}
