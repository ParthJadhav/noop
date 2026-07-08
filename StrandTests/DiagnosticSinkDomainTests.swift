import XCTest
import StrandAnalytics
@testable import Strand

@MainActor
final class DiagnosticSinkDomainTests: XCTestCase {

    // The widened sink takes (String, TestDomain?). A tagged emitter forwards its domain through.
    func testSinkForwardsDomain() {
        var captured: [(String, TestDomain?)] = []
        // Construct the engine with the project's real, lightweight in-memory dependencies.
        let engine = IntelligenceEngine(repo: Repository(deviceId: "test"), profile: ProfileStore(), deviceId: "test")
        engine.diagnosticSink = { line, domain in captured.append((line, domain)) }
        engine.diagnosticSink?("rest sub-scores dur=.5", .sleep)
        engine.diagnosticSink?("untagged line", nil)
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].0, "rest sub-scores dur=.5")
        XCTAssertEqual(captured[0].1, .sleep)
        XCTAssertNil(captured[1].1)
    }
}
