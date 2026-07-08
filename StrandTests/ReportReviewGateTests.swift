import XCTest
@testable import Strand
import StrandAnalytics

/// The review-before-share gate is mandatory and not skippable (spec sections 9, 12). It must surface
/// the exact text the user is about to share (so they can redact), and only clear on an explicit
/// confirm. A fresh gate, or one the user dismissed, never reports cleared.
final class ReportReviewGateTests: XCTestCase {

    private func sampleEntries() -> [FileExport.BundleEntry] {
        [FileExport.BundleEntry(name: "report.txt",
                                data: Data("NOOP strap log\nline 1\nline 2".utf8))]
    }

    func testFreshGateIsNotCleared() {
        let gate = ReportReviewGate(entries: sampleEntries())
        XCTAssertFalse(gate.isCleared)
    }

    func testPreviewShowsTheReportTextUserWillShare() {
        let gate = ReportReviewGate(entries: sampleEntries())
        XCTAssertTrue(gate.previewText.contains("line 1"))
        XCTAssertTrue(gate.previewText.contains("line 2"))
    }

    func testConfirmClearsAndCancelDoesNot() {
        var gate = ReportReviewGate(entries: sampleEntries())
        gate.cancel()
        XCTAssertFalse(gate.isCleared)
        gate.confirm()
        XCTAssertTrue(gate.isCleared)
    }
}
