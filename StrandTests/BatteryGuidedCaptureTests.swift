import XCTest
import StrandAnalytics
@testable import Strand

/// The Battery guided multi-day status: full-days-elapsed against the target, the days-twin of the Sleep
/// nights accountant. Pins the day boundaries so the Test Centre Battery row never miscounts (#713, Test
/// Centre). Twin of the Android BatteryGuidedCaptureTest. No em-dashes.
@MainActor
final class BatteryGuidedCaptureTests: XCTestCase {

    func testStatusCountsElapsedDaysAgainstTarget() {
        let started = Date(timeIntervalSince1970: 0)
        // 0 full days in -> day 1 of 3.
        XCTAssertEqual(BatteryGuidedCapture.statusText(startedAt: started, target: 3,
                       now: Date(timeIntervalSince1970: 3600)), "Capturing day 1 of 3")
        // 2 full days in -> day 3 of 3.
        XCTAssertEqual(BatteryGuidedCapture.statusText(startedAt: started, target: 3,
                       now: Date(timeIntervalSince1970: 2 * 86400 + 3600)), "Capturing day 3 of 3")
        // Past the window -> done.
        XCTAssertEqual(BatteryGuidedCapture.statusText(startedAt: started, target: 3,
                       now: Date(timeIntervalSince1970: 3 * 86400)), "Capture complete, 3 of 3 days")
    }

    func testStatusNilStartIsNotStarted() {
        XCTAssertEqual(BatteryGuidedCapture.statusText(startedAt: nil, target: 3,
                       now: Date(timeIntervalSince1970: 100)), "Not started")
    }
}
