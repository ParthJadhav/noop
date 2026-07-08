import XCTest
@testable import Strand

final class MacEnvHeaderTests: XCTestCase {

    #if os(macOS)
    // On macOS the block is now net-new and must carry the OS version plus the charging/AC plus signing lines.
    func testMacSummaryLinesPopulated() {
        let lines = IOSDiagnostics.capture().summaryLines()
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.contains { $0.hasPrefix("macOS:") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Power:") })          // AC vs battery
        XCTAssertTrue(lines.contains { $0.hasPrefix("Signed / notarized:") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("App Sandbox:") })
        // Degrade gracefully: never fabricate an iOS-only field on macOS.
        XCTAssertFalse(lines.contains { $0.hasPrefix("Background refresh:") })
        XCTAssertFalse(lines.contains { $0.hasPrefix("Sideload expiry:") })
    }
    #endif
}
