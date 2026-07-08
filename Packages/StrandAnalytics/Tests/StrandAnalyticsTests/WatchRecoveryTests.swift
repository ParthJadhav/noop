import XCTest
@testable import StrandAnalytics

/// Tests for `WatchRecovery`, the honesty-critical recovery-from-daily-aggregate engine behind
/// "Apple Watch as a device". The watch gives sparse daily SDNN + resting HR rather than the
/// strap's dense RR stream, so these fixtures pin the BEHAVIOUR (at-baseline ≈ mid, high-HRV /
/// low-RHR → high, thin history / missing today → nil + calibrating) regardless of the exact
/// logistic constants, which are inherited unchanged from `RecoveryScorer` (the strap Charge
/// engine) so watch recovery and strap recovery sit on the same scale.
final class WatchRecoveryTests: XCTestCase {

    // A person whose HRV today equals their baseline and RHR equals baseline → mid recovery,
    // solid confidence (14 nights of history clears the trusted gate).
    func testAtBaselineGivesMidRecoverySolid() {
        let hist = Array(repeating: 45.0, count: 14)            // 14 nights of SDNN
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 52,
                                        sdnnHistory: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        XCTAssertGreaterThanOrEqual(out.recovery!, 40)
        XCTAssertLessThanOrEqual(out.recovery!, 60)
        XCTAssertEqual(out.confidence, .solid)
    }

    // HRV well above baseline + RHR below baseline → high recovery.
    func testHighHRVLowRHRGivesHighRecovery() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = WatchRecovery.compute(todaySDNN: 70.0, todayRHR: 46,
                                        sdnnHistory: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        XCTAssertGreaterThan(out.recovery!, 65)
    }

    // HRV well below baseline + RHR above baseline → low recovery (the symmetric case;
    // a bad night must read low, not get floored at mid).
    func testLowHRVHighRHRGivesLowRecovery() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = WatchRecovery.compute(todaySDNN: 22.0, todayRHR: 62,
                                        sdnnHistory: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        XCTAssertLessThan(out.recovery!, 40)
    }

    // Too little history → calibrating, nil recovery (never a fabricated number).
    func testInsufficientHistoryCalibrates() {
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 52,
                                        sdnnHistory: [45, 46], rhrHistory: [52, 51])
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // History just under the week gate → still calibrating (the gate is exactly minBaselineNights).
    func testHistoryJustBelowGateCalibrates() {
        let n = WatchRecovery.minBaselineNights - 1
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 52,
                                        sdnnHistory: Array(repeating: 45.0, count: n),
                                        rhrHistory: Array(repeating: 52.0, count: n))
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // History at the week gate (and usable baseline) → scores, no longer calibrating.
    func testHistoryAtGateScores() {
        let n = WatchRecovery.minBaselineNights
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: 52,
                                        sdnnHistory: Array(repeating: 45.0, count: n),
                                        rhrHistory: Array(repeating: 52.0, count: n))
        XCTAssertNotNil(out.recovery)
        XCTAssertNotEqual(out.confidence, .calibrating)
    }

    // Missing today's HRV → calibrating, nil (we never score off RHR alone).
    func testMissingTodayCalibrates() {
        let out = WatchRecovery.compute(todaySDNN: nil, todayRHR: 52,
                                        sdnnHistory: Array(repeating: 45.0, count: 14),
                                        rhrHistory: Array(repeating: 52.0, count: 14))
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // Missing today's RHR (but HRV present + baseline usable) → still scores off HRV alone,
    // honestly, rather than nil-ing out. RHR is an optional term.
    func testMissingTodayRHRStillScoresFromHRV() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = WatchRecovery.compute(todaySDNN: 45.0, todayRHR: nil,
                                        sdnnHistory: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        // At-baseline HRV with the RHR term dropped should still land near the mid band.
        XCTAssertGreaterThanOrEqual(out.recovery!, 40)
        XCTAssertLessThanOrEqual(out.recovery!, 70)
    }

    // Watch recovery is on the SAME scale as strap recovery: feeding identical at-baseline inputs
    // to RecoveryScorer directly (HRV + RHR terms only) reproduces WatchRecovery's number.
    func testSameScaleAsStrapRecovery() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = WatchRecovery.compute(todaySDNN: 58.0, todayRHR: 50,
                                        sdnnHistory: hist, rhrHistory: rhrHist)
        let hrvBase = Baselines.foldHistory(hist.map { Optional($0) }, cfg: Baselines.hrvCfg)
        let rhrBase = Baselines.foldHistory(rhrHist.map { Optional($0) }, cfg: Baselines.restingHRCfg)
        let strap = RecoveryScorer.recovery(hrv: 58.0, rhr: 50.0, resp: nil,
                                            hrvBaseline: hrvBase, rhrBaseline: rhrBase,
                                            respBaseline: nil, sleepPerf: nil)
        XCTAssertNotNil(out.recovery)
        XCTAssertNotNil(strap)
        XCTAssertEqual(out.recovery!, strap!, accuracy: 0.0001)
    }
}
