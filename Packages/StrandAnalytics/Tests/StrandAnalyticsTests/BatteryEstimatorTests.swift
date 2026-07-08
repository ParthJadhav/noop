import XCTest
@testable import StrandAnalytics

final class BatteryEstimatorTests: XCTestCase {

    private let h = 3600

    func testNilWhenNoSamples() {
        XCTAssertNil(BatteryEstimator.estimate(samples: [], ratedHours: BatteryEstimator.ratedLifeHoursWhoop5))
    }

    func testMeasuredRateFromCleanDischarge() {
        // 100% to 90% over 10h is 1 %/h; at 90% that leaves 90h, from the user's own discharge.
        let e = BatteryEstimator.estimate(samples: [(0, 100), (10 * h, 90)],
                                          ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)!
        XCTAssertEqual(e.source, .measured)
        XCTAssertEqual(e.remainingHours, 90, accuracy: 1e-6)
        XCTAssertEqual(e.hoursRemaining, 90, accuracy: 1e-6)
        XCTAssertEqual(e.daysRemaining, 90.0 / 24, accuracy: 1e-6)
        XCTAssertEqual(e.currentSoc, 90, accuracy: 1e-6)
    }

    func testRatedFallbackWhenSpanTooShort() {
        // A single reading has no span to fit, so it falls back to rated: 50 / (100/108) = 54h.
        let e = BatteryEstimator.estimate(samples: [(0, 50)],
                                          ratedHours: BatteryEstimator.ratedLifeHoursWhoop4)!
        XCTAssertEqual(e.source, .rated)
        XCTAssertEqual(e.remainingHours, 54, accuracy: 1e-6)
    }

    func testChargeRestartsTheDischargeRun() {
        // Discharge 100->70, then a charge back to 100, then 100->88 over 6h. The rate is fit on the
        // post-charge segment only (2 %/h), never across the charge.
        let e = BatteryEstimator.estimate(samples: [(0, 100), (4 * h, 70), (5 * h, 100), (11 * h, 88)],
                                          ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)!
        XCTAssertEqual(e.source, .measured)
        XCTAssertEqual(e.remainingHours, 44, accuracy: 1e-6)   // 88 / 2
    }

    func testPartialTopUpDoesNotInflateDaysLeft() {
        // #8: a partial top-up must NOT reset the discharge run like a full charge. Buffer is a long clean
        // discharge 100%->40% over 60h (1 %/h), a quick desk top-up 40->55 at 61h, then 55->53 over 3h. The
        // old scan anchored the run on the +15pp top-up and fit ~0.67 %/h on the 3h tail, inflating the
        // estimate. With the near-full guard the top-up is stepped over, the fit prefers the long pre-top-up
        // segment (1 %/h), and at 53% that is an honest ~53h, not the inflated ~79h.
        let e = BatteryEstimator.estimate(
            samples: [(0, 100), (60 * h, 40), (61 * h, 55), (64 * h, 53)],
            ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)!
        XCTAssertEqual(e.source, .measured)
        XCTAssertEqual(e.currentSoc, 53, accuracy: 1e-6)
        XCTAssertEqual(e.remainingHours, 53, accuracy: 1e-6)   // 53 / (1 %/h), pre-top-up slope
    }

    func testMeasuredFromRecentDischargeWithoutNearFullCharge() {
        // #919: a WHOOP 5.0 that never tops past 90% - SoC rises 16->52, then discharges 52->44 over 8h. The
        // old scan found no near-full anchor and fell back to the OLDEST (16%) reading, so the window netted
        // to a CHARGE (drop<0) and the estimate stayed on rated. Anchoring at the buffer's max (52%) fits the
        // real 1 %/h discharge -> measured, 44h. (Distinct from #8, whose buffer already starts at its max.)
        let e = BatteryEstimator.estimate(
            samples: [(0, 16), (4 * h, 52), (12 * h, 44)],
            ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)!
        XCTAssertEqual(e.source, .measured)
        XCTAssertEqual(e.currentSoc, 44, accuracy: 1e-6)
        XCTAssertEqual(e.remainingHours, 44, accuracy: 1e-6)   // 52->44 = 8pp over 8h = 1 %/h; 44 / 1
    }

    func testNearFullChargeStillResetsTheRun() {
        // The guard must NOT change a genuine near-full charge: discharge 100->20, charge back to 95 (>=90,
        // near-full), then 95->85 over 5h is 2 %/h. The run still resets on the near-full charge, source
        // measured, 85 / 2 = 42.5h. This pins that the near-full anchor still fires (no regression of #713).
        let e = BatteryEstimator.estimate(
            samples: [(0, 100), (8 * h, 20), (9 * h, 95), (14 * h, 85)],
            ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)!
        XCTAssertEqual(e.source, .measured)
        XCTAssertEqual(e.remainingHours, 42.5, accuracy: 1e-6)   // 85 / 2, post-near-full-charge segment
    }

    func testRatedFallbackWhenDropTooSmall() {
        // 100->99 over 10h is a 1% drop, under minDropPct(2), so it falls back to rated instead of
        // reporting a wild ~1000h. The estimate stays anchored to the latest SoC.
        let e = BatteryEstimator.estimate(samples: [(0, 100), (10 * h, 99)],
                                          ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)!
        XCTAssertEqual(e.source, .rated)
        XCTAssertEqual(e.remainingHours, 285.12, accuracy: 1e-6)   // 99 / (100/288)
    }

    func testClampsToOneAndAHalfTimesRated() {
        // A slow drain near full charge must not report more than 1.5x the rated life. 100% to 90% over
        // 20h is 0.5 %/h, current 90% -> 180h raw, clamped to 108*1.5 = 162h.
        let e = BatteryEstimator.estimate(samples: [(0, 100), (20 * h, 90)],
                                          ratedHours: BatteryEstimator.ratedLifeHoursWhoop4)!
        XCTAssertEqual(e.source, .measured)
        XCTAssertEqual(e.remainingHours, 162, accuracy: 1e-6)   // clamped, not 200
    }

    func testUnsortedSamplesAreHandled() {
        // Same two points as the clean-discharge case but out of order: result must match.
        let e = BatteryEstimator.estimate(samples: [(10 * h, 90), (0, 100)],
                                          ratedHours: BatteryEstimator.ratedLifeHoursWhoop5)!
        XCTAssertEqual(e.source, .measured)
        XCTAssertEqual(e.remainingHours, 90, accuracy: 1e-6)
        XCTAssertEqual(e.currentSoc, 90, accuracy: 1e-6)
    }

    func testLabelSwitchesHoursToDaysAt48h() {
        XCTAssertEqual(BatteryEstimator.label(hours: 14), "~14h")
        XCTAssertEqual(BatteryEstimator.label(hours: 108), "~4.5 days")
    }
}
