import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class SleepReadoutTests: XCTestCase {
    func testHrDensityPerMinute() {
        // 600 HR samples over 599 s span -> ~60 samples/min.
        let start = 1_749_513_600
        let hr = (0..<600).map { HRSample(ts: start + $0, bpm: 50) }
        let d = SleepReadout.hrDensityPerMinute(hr: hr)
        XCTAssertEqual(d, 60.1, accuracy: 0.2)
    }

    func testHrDensityFewerThanTwoSamplesIsZero() {
        XCTAssertEqual(SleepReadout.hrDensityPerMinute(hr: []), 0)
        XCTAssertEqual(SleepReadout.hrDensityPerMinute(hr: [HRSample(ts: 0, bpm: 50)]), 0)
    }

    func testGravityCoverageFraction() {
        // Gravity spanning the whole HR window -> coverage ~1.0 (dense, not sparse).
        let start = 1_749_513_600
        let hr = (0..<600).map { HRSample(ts: start + $0, bpm: 50) }
        let grav = (0..<600).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
        let c = SleepReadout.gravityCoverageFraction(gravity: grav, hr: hr)
        XCTAssertGreaterThan(c, 0.9)
    }

    func testGravityCoverageSparseIsBelowGate() {
        // Gravity clumped into the first quarter of the HR window -> sparse (< sparseGravitySpanFrac).
        let start = 1_749_513_600
        let hr = (0..<600).map { HRSample(ts: start + $0, bpm: 50) }
        let grav = (0..<150).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
        let c = SleepReadout.gravityCoverageFraction(gravity: grav, hr: hr)
        XCTAssertLessThan(c, SleepStager.sparseGravitySpanFrac)
    }

    func testLastGateFiredParsesTaggedTail() {
        let tail = [
            "[sleep] gate run=0 spanS=1800 DROPPED gate=minSleepMin spanMin=30 minSleepMin=60",
            "[sleep] gate run=1 spanS=5400 KEPT gate=accepted spanMin=90 eff=0.9 restingHR=50 daytime=false",
        ]
        XCTAssertEqual(SleepReadout.lastGateFired(taggedTail: tail), "accepted")
    }

    func testLastGateFiredNilWhenNoGateLine() {
        XCTAssertNil(SleepReadout.lastGateFired(taggedTail: ["[sleep] sleep day=2021-06-17 totalSleepMin=420"]))
        XCTAssertNil(SleepReadout.lastGateFired(taggedTail: []))
    }
}

/// The Recovery / HRV live-readout parsers (Test Centre Group G). Twin of the Android TestReadout tests.
final class TestReadoutTests: XCTestCase {
    func testLastChargeBreakdownParsesScoreAndBand() {
        let tail = [
            "[recovery] charge day=2021-06-17 baseline hrv mean=50.0 spread=4.79 nValid=14 status=trusted",
            "[recovery] charge day=2021-06-17 score=62.5 band=yellow (logistic k=1.6 z0=-0.2)",
        ]
        XCTAssertEqual(TestReadout.lastChargeBreakdown(taggedTail: tail), "score=62.5 band=yellow")
    }

    func testLastChargeBreakdownFallsBackToNilReason() {
        let tail = ["[recovery] charge day=2021-06-17 nilScore reason=hrvBaselineNotUsable hrvStatus=calibrating hrvNValid=2 (need nValid>=4)"]
        XCTAssertEqual(TestReadout.lastChargeBreakdown(taggedTail: tail), "no score (hrvBaselineNotUsable)")
    }

    func testLastChargeBreakdownNilWhenNoTrace() {
        XCTAssertNil(TestReadout.lastChargeBreakdown(taggedTail: []))
        XCTAssertNil(TestReadout.lastChargeBreakdown(taggedTail: ["[sleep] gate run=0 ... gate=accepted"]))
    }

    func testLastHrvComputationParsesRmssdFragment() {
        let tail = [
            "[hrv] hrv path=spot nInput=60 nClean=58 rejectedFraction=0.03",
            "[hrv] hrv rmssd=42.1ms sdnn=55.3ms meanNN=812.0ms",
        ]
        XCTAssertEqual(TestReadout.lastHrvComputation(taggedTail: tail), "rmssd=42.1ms sdnn=55.3ms meanNN=812.0ms")
    }

    func testLastHrvComputationReportsFilteredOut() {
        let tail = ["[hrv] hrv result=nil (a gate above refused the reading)"]
        XCTAssertEqual(TestReadout.lastHrvComputation(taggedTail: tail), "no reading (filtered out)")
    }
}
