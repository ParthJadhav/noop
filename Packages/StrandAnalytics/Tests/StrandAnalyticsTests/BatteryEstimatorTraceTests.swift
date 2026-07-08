import XCTest
@testable import StrandAnalytics

/// The Battery test mode's pure SoC-series + discharge-run + slope + gate trace. Pins the exact lines a
/// fixture series produces AND proves the emitter never changes the engine value `estimate(...)` returns
/// (#713, Test Centre). Twin of the Android BatteryEstimatorTraceTest. No em-dashes.
final class BatteryEstimatorTraceTests: XCTestCase {

    private let h = 3600

    func testTraceNilWhenNoSamples() {
        let (estimate, lines) = BatteryEstimator.estimateTrace(
            samples: [], ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)
        XCTAssertNil(estimate)
        XCTAssertEqual(lines, ["battery series=0 readings, no reading to anchor to"])
    }

    func testTraceEmitsSeriesChargeStepRunSlopeAndGate() {
        // Same fixture as the discharge-restart case: discharge 100->70, a charge back to 100 at 5h, then
        // 100->88 over 6h. The run is fit on the post-charge segment only (2 %/h), source measured.
        let samples: [(ts: Int, soc: Double)] = [(0, 100), (4 * h, 70), (5 * h, 100), (11 * h, 88)]
        let (estimate, lines) = BatteryEstimator.estimateTrace(
            samples: samples, ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)

        // The emitter must NOT change the engine result (byte-identical to estimate()).
        let plain = BatteryEstimator.estimate(samples: samples,
                                              ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)
        XCTAssertEqual(estimate, plain)

        XCTAssertEqual(lines, [
            "battery series=4 readings span 0..39600s",
            "battery read t=0s soc=100.0",
            "battery read t=14400s soc=70.0",
            "battery read t=18000s soc=100.0",
            "battery read t=39600s soc=88.0",
            "battery chargeStep at t=18000s +30.0pp (>chargeStepPct 1.0)",
            "battery dischargeRun start=18000s span=6.0h drop=12.0pp",
            "battery slope=2.0pct/h fitted from run endpoints",
            "battery gate minSpanHours 2.0 PASS, minDropPct 2.0 PASS -> source=measured",
        ])
    }

    func testTracePartialTopUpFitsPreTopUpSegment() {
        // #8: a partial top-up (40->55, below nearFullPct 90) does NOT anchor the run. The trace reports it
        // as a partialTopUp, the fit prefers the long pre-top-up discharge (100->40 over 60h = 1 %/h), and
        // source stays measured at an honest ~53h, not the inflated short-tail rate.
        let samples: [(ts: Int, soc: Double)] = [(0, 100), (60 * h, 40), (61 * h, 55), (64 * h, 53)]
        let (estimate, lines) = BatteryEstimator.estimateTrace(
            samples: samples, ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)

        // The emitter must NOT change the engine result (byte-identical to estimate()).
        let plain = BatteryEstimator.estimate(samples: samples,
                                              ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)
        XCTAssertEqual(estimate, plain)

        XCTAssertEqual(lines, [
            "battery series=4 readings span 0..230400s",
            "battery read t=0s soc=100.0",
            "battery read t=216000s soc=40.0",
            "battery read t=219600s soc=55.0",
            "battery read t=230400s soc=53.0",
            "battery partialTopUp at t=219600s +15.0pp (<nearFullPct 90.0) -> fit pre-top-up segment",
            "battery dischargeRun start=0s span=60.0h drop=60.0pp",
            "battery slope=1.0pct/h fitted from run endpoints",
            "battery gate minSpanHours 2.0 PASS, minDropPct 2.0 PASS -> source=measured",
        ])
        // No full-charge chargeStep line: the only rise here is a partial top-up.
        XCTAssertFalse(lines.contains { $0.hasPrefix("battery chargeStep") })
    }

    func testTraceGateDropToRatedWhenDropTooSmall() {
        // 100->99 over 10h is a 1pp drop, under minDropPct 2, so the gate fails and source=rated.
        let samples: [(ts: Int, soc: Double)] = [(0, 100), (10 * h, 99)]
        let (estimate, lines) = BatteryEstimator.estimateTrace(
            samples: samples, ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)
        XCTAssertEqual(estimate?.source, .rated)
        XCTAssertTrue(lines.contains(
            "battery gate minSpanHours 2.0 PASS, minDropPct 2.0 FAIL -> source=rated"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("battery chargeStep") })
    }
}
