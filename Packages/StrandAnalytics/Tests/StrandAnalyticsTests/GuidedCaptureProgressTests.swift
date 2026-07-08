import XCTest
@testable import StrandAnalytics

final class GuidedCaptureProgressTests: XCTestCase {
    func testCapturingState() {
        // 2 of 3 nights have data -> still capturing, next nudge tonight.
        let p = GuidedCaptureProgress.evaluate(target: 3, nightsWithData: 2, nightsElapsed: 2)
        XCTAssertEqual(p, .capturing(done: 2, target: 3))
    }
    func testGapNight() {
        // 3 nights elapsed but only 1 has data -> a gap was recorded, keep going.
        let p = GuidedCaptureProgress.evaluate(target: 3, nightsWithData: 1, nightsElapsed: 3)
        XCTAssertEqual(p, .capturing(done: 1, target: 3))
    }
    func testComplete() {
        let p = GuidedCaptureProgress.evaluate(target: 3, nightsWithData: 3, nightsElapsed: 3)
        XCTAssertEqual(p, .complete)
    }
    func testCompleteWhenOverTarget() {
        let p = GuidedCaptureProgress.evaluate(target: 3, nightsWithData: 4, nightsElapsed: 5)
        XCTAssertEqual(p, .complete)
    }
    func testLabels() {
        XCTAssertEqual(GuidedCaptureProgress.label(for: .complete), "Capture complete. Tap Report to export.")
        XCTAssertEqual(GuidedCaptureProgress.label(for: .capturing(done: 1, target: 3)),
                       "Captured 1 of 3 nights. Wear it again tonight.")
        XCTAssertEqual(GuidedCaptureProgress.gapNudge(), "No data last night. Wear the strap tonight to continue.")
    }
    func testNoEmDashInLabel() {
        XCTAssertFalse(GuidedCaptureProgress.label(for: .capturing(done: 1, target: 3)).contains("\u{2014}"))
        XCTAssertFalse(GuidedCaptureProgress.label(for: .complete).contains("\u{2014}"))
        XCTAssertFalse(GuidedCaptureProgress.gapNudge().contains("\u{2014}"))
    }
}
