import XCTest
@testable import Strand

/// The Report flow must not share an uncleared bundle (spec section 12: review is not skippable).
final class TestReportFlowGatedTests: XCTestCase {

    private func entries() -> [FileExport.BundleEntry] {
        [FileExport.BundleEntry(name: "report.txt", data: Data("x".utf8))]
    }

    func testUnclearedGateBlocksProceed() {
        let gate = ReportReviewGate(entries: entries())
        XCTAssertFalse(TestReportFlow.shouldProceed(gate: gate))
    }

    func testClearedGateAllowsProceed() {
        var gate = ReportReviewGate(entries: entries())
        gate.confirm()
        XCTAssertTrue(TestReportFlow.shouldProceed(gate: gate))
    }
}
