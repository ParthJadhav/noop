import XCTest
@testable import StrandAnalytics

/// Pins the canonical Battery test mode contract (title, questionnaire ids, readout ids, capture ids,
/// guided-days default) so a drafter drift breaks the build (#713, Test Centre). No em-dashes.
final class BatteryRegistryTests: XCTestCase {

    func testBatteryModeCanonicalContract() {
        let m = TestModeRegistry.battery
        XCTAssertEqual(m.domain, .battery)
        XCTAssertEqual(m.title, "Battery & Charging")
        XCTAssertEqual(m.questionnaire.map(\.id),
                       ["whoopAppInstalled", "otherPhonePaired", "chargedInWindow", "batterySaverApps"])
        XCTAssertEqual(m.liveReadout, ["currentSoc", "estimateDaysLeft", "slopeSource"])
        XCTAssertEqual(m.captures,
                       ["socSeries", "chargeSteps", "offWristGaps", "dischargeRun", "fittedSlope",
                        "sourceMeasuredVsRated", "batteryGates"])
        if case .guided(let unit, let count) = m.capture {
            XCTAssertEqual(unit, .days)
            XCTAssertEqual(count, 3)
        } else {
            XCTFail("Battery mode must be guided days")
        }
    }
}
