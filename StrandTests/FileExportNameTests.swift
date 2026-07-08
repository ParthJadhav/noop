import XCTest
@testable import Strand

final class FileExportNameTests: XCTestCase {

    func testBundleNamePattern() {
        // A fixed date so the yyMMdd-HHmm stamp is deterministic: 2026-06-26 07:12 UTC.
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 26; c.hour = 7; c.minute = 12
        c.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar(identifier: .gregorian).date(from: c)!
        // The stamp uses the local zone, so assert structure not the exact time.
        let name = FileExport.bundleName(profile: "sleep", platform: "ios", version: "7.3.0", date: date)
        XCTAssertTrue(name.hasPrefix("noop-sleep-ios-v7.3.0-"))
        XCTAssertTrue(name.hasSuffix(".zip"))
        // noop-sleep-ios-v7.3.0-YYMMDD-HHMM.zip
        let stampPart = name.dropFirst("noop-sleep-ios-v7.3.0-".count).dropLast(".zip".count)
        XCTAssertEqual(stampPart.count, 11)  // "260626-0712"
        XCTAssertTrue(stampPart.contains("-"))
    }

    func testTimestampedNameStillTwoArg() {
        // The old 2-arg form must keep compiling for the existing strap-log/raw-capture callers.
        let n = FileExport.timestampedName("noop-strap-log", ext: "txt")
        XCTAssertTrue(n.hasPrefix("noop-strap-log-"))
        XCTAssertTrue(n.hasSuffix(".txt"))
    }
}
