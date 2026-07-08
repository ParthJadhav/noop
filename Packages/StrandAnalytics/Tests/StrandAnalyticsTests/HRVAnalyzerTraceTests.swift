import XCTest
@testable import StrandAnalytics

/// The HRV & Autonomic test mode's pure cleaning trace. Pins the lines a fixture beat series produces AND
/// proves the emitter never changes the HRVResult `analyze(...)` returns (Test Centre Group G). Twin of
/// the Android HrvAnalyzerTraceTest. No em-dashes.
final class HRVAnalyzerTraceTests: XCTestCase {

    func testTraceResultIsByteIdenticalToAnalyze() {
        // 22 clean intervals near 800 ms, the same golden series HRVAnalyzerTests uses.
        let nn: [Double] = [800, 810, 805, 815, 800, 820, 810, 800, 815, 805, 810,
                            800, 820, 815, 805, 810, 800, 815, 810, 805, 800, 820]
        let plain = HRVAnalyzer.analyze(rawRR: nn)
        let (traced, lines) = HRVAnalyzer.analyzeTrace(rawRR: nn)
        XCTAssertEqual(traced, plain)
        XCTAssertTrue(lines.contains { $0.contains("nInput=22") && $0.contains("nClean=22") })
        XCTAssertTrue(lines.contains { $0.contains("minBeats need=20") && $0.contains("CLEARED") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("hrv rmssd=") })
        XCTAssertFalse(lines.contains { $0.contains("\u{2014}") })
    }

    func testTraceReportsMinBeatsFailureAndNilResult() {
        // 19 clean intervals → below minBeats(20) → empty result.
        let rr = Array(repeating: 800.0, count: 19)
        let plain = HRVAnalyzer.analyze(rawRR: rr)
        let (traced, lines) = HRVAnalyzer.analyzeTrace(rawRR: rr)
        XCTAssertEqual(traced, plain)
        XCTAssertNil(traced.rmssd)
        XCTAssertTrue(lines.contains { $0.contains("minBeats need=20 clean=19 FAILED") })
        XCTAssertTrue(lines.contains { $0.contains("result=nil") })
    }

    func testTraceReportsRangeAndEctopicRejection() {
        // 21 in-range near 800 + one 250 ms (out of range) + one wild 1600 ms (ectopic vs ~800 median).
        var rr: [Double] = Array(repeating: 800.0, count: 21)
        rr.insert(250.0, at: 0)       // out of range (< rrMinMs)
        rr.insert(1600.0, at: 5)      // in range but >20% off the local median → ectopic
        let (traced, lines) = HRVAnalyzer.analyzeTrace(rawRR: rr)
        XCTAssertEqual(traced, HRVAnalyzer.analyze(rawRR: rr))
        let rejectLine = lines.first { $0.hasPrefix("hrv reject ") }
        XCTAssertNotNil(rejectLine)
        XCTAssertTrue(rejectLine!.contains("range=1"))
        XCTAssertTrue(rejectLine!.contains("ectopic=1"))
    }

    func testSpotGateLineOnlyWhenCeilingSupplied() {
        let nn: [Double] = Array(repeating: 800.0, count: 22)
        // Nightly/continuous path (nil ceiling): no spotGate line, byte-identical to analyze().
        let (_, contLines) = HRVAnalyzer.analyzeTrace(rawRR: nn, maxRejectedFraction: nil, path: "continuous")
        XCTAssertFalse(contLines.contains { $0.contains("spotGate") })
        XCTAssertTrue(contLines.contains { $0.contains("path=continuous") })
        // Spot path (ceiling supplied): the gate line is present.
        let (_, spotLines) = HRVAnalyzer.analyzeTrace(
            rawRR: nn, maxRejectedFraction: HRVAnalyzer.defaultSpotMaxRejectedFraction, path: "spot")
        XCTAssertTrue(spotLines.contains { $0.contains("spotGate") && $0.contains("PASS") })
    }
}
