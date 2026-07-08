import XCTest
@testable import Strand

/// #696 — STOPGAP guard on the "HRV X% over baseline" Synthesis headline.
///
/// NOOP mixes HRV measurement methods on the shared `avgHrv` field: strap/WHOOP-CSV HRV is RMSSD
/// (~20-100 ms) while Apple-Health-imported HRV is SDNN (~100-200 ms). With no method awareness, an
/// SDNN reading (e.g. an Oura ring's 176 ms) compared against an RMSSD baseline (~57 ms) yields a
/// physiologically-impossible delta (+209%) and renders the alarming "210% over baseline" headline.
/// The fix suppresses the percentage comparison (returns nil → the insight falls back to the
/// qualitative recovery-state word) once the magnitude exceeds the ~±100% ceiling of real
/// night-to-night HRV variation. These pin that gate on the pure delta core.
final class TodayHrvBaselineDeltaTests: XCTestCase {

    // 4 prior nights = exactly Baselines.minNightsSeed, so the seed gate is satisfied and the delta
    // is computed (not nil for lack of history). Mean of these is 57.5 ms — an RMSSD-scale baseline.
    private let rmssdBaseline: [Double] = [55, 60, 56, 59]

    // MARK: the bug — an implausibly large delta is suppressed (falls back to nil → state word)

    func testImplausiblyLargeDelta_isSuppressed_returnsNil() {
        // The #696 scenario: today's value is an SDNN reading (~176 ms) compared against the RMSSD
        // baseline (~57.5 ms) → +206%. That must NOT render a triple-digit "over baseline" headline.
        let pct = TodayView.hrvBaselineDeltaPct(today: 176, priorHrvs: rmssdBaseline)
        XCTAssertNil(pct, "an SDNN reading vs an RMSSD baseline (~+206%) must be suppressed, not shown")
    }

    func testThreeTimesBaseline_isSuppressed_returnsNil() {
        // A reading 3× the baseline (~+200%) is a units/method artifact, not a real night-to-night
        // swing — it must not produce a triple-digit "over baseline" headline.
        let baseline = rmssdBaseline.reduce(0, +) / Double(rmssdBaseline.count)  // 57.5
        let pct = TodayView.hrvBaselineDeltaPct(today: baseline * 3, priorHrvs: rmssdBaseline)
        XCTAssertNil(pct, "a 3× reading (+200%) must be suppressed so no triple-digit headline renders")
    }

    func testSuppressedDeltaNeverRendersTripleDigitHeadline() {
        // End-to-end honesty check: whatever the implausible reading, the synthesized headline a caller
        // would build ("HRV \(abs(pct))% over baseline") must never carry a triple-digit percentage,
        // because the delta core refuses to supply one. Sweep a few artifact-scale readings.
        for today in [176.0, 200.0, 250.0, 1.0] {   // huge (SDNN) and tiny (degenerate) both implausible
            if let pct = TodayView.hrvBaselineDeltaPct(today: today, priorHrvs: rmssdBaseline) {
                XCTAssertLessThan(abs(pct), 100,
                    "a returned delta of \(pct)% would render a misleading headline for today=\(today)")
            }
        }
    }

    func testBelowBaselineNegativeDelta_isAlsoSuppressed_whenImplausible() {
        // The guard is symmetric: a near-zero reading vs a normal baseline (~-98%+) is just as much an
        // artifact as a huge positive one, and must not render "HRV 98% under baseline".
        let pct = TodayView.hrvBaselineDeltaPct(today: 0.5, priorHrvs: rmssdBaseline)
        XCTAssertNil(pct, "an implausibly low reading (~-99%) must be suppressed too")
    }

    // MARK: the happy path — a genuine night-to-night swing still reports its percentage

    func testPlausiblePositiveDelta_isReported() {
        // A real swing inside the ±100% band must still surface its honest percentage. today=69 vs
        // baseline 57.5 → +20%.
        let pct = TodayView.hrvBaselineDeltaPct(today: 69, priorHrvs: rmssdBaseline)
        XCTAssertEqual(pct, 20, "a plausible +20% night must still be reported")
    }

    func testPlausibleNegativeDelta_isReported() {
        // today=46 vs baseline 57.5 → -20%.
        let pct = TodayView.hrvBaselineDeltaPct(today: 46, priorHrvs: rmssdBaseline)
        XCTAssertEqual(pct, -20, "a plausible -20% night must still be reported")
    }

    func testExactlyAtThreshold_isReported() {
        // The threshold is inclusive at ±100%: today = 2× baseline (115 vs 57.5) → exactly +100%, still shown.
        let pct = TodayView.hrvBaselineDeltaPct(today: 115, priorHrvs: rmssdBaseline)
        XCTAssertEqual(pct, 100, "a delta sitting exactly at the +100% ceiling is still shown")
    }

    // MARK: the seed gate is preserved (no regression to the calibrating behaviour)

    func testNotEnoughPriorNights_returnsNil() {
        // Fewer than Baselines.minNightsSeed valid prior nights → no stable baseline → nil (calibrating).
        let pct = TodayView.hrvBaselineDeltaPct(today: 69, priorHrvs: [55, 60, 56])
        XCTAssertNil(pct, "below the seed gate the delta must stay nil (mid-calibration)")
    }

    func testNonPositiveToday_returnsNil() {
        XCTAssertNil(TodayView.hrvBaselineDeltaPct(today: 0, priorHrvs: rmssdBaseline))
    }
}
