import XCTest
@testable import WhoopStore

final class PairedDeviceSourceKindTests: XCTestCase {
    func testLiveAppleWatchSourceKindExists() {
        XCTAssertEqual(SourceKind(rawValue: "liveAppleWatch"), .liveAppleWatch)
        XCTAssertTrue(SourceKind.allCases.contains(.liveAppleWatch))
    }
}
