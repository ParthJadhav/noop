import XCTest
import StrandAnalytics
@testable import Strand

/// The Battery test mode's gated per-sample emit: banking a SoC reading drops one tagged (t, soc) line
/// when the mode is on, and NOTHING when it is off (the zero-cost-when-off contract). Twin of the Android
/// BatterySocLineFormatTest's shape (#713, Test Centre). No em-dashes.
@MainActor
final class BatteryBankTraceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "testcentre.active.battery")
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "testcentre.active.battery")
        super.tearDown()
    }

    func testBankEmitsTaggedSocLineWhenBatteryModeActive() {
        let live = LiveState()
        live.bankBatterySample(80, now: 1000)
        XCTAssertTrue(live.log.contains { $0.contains("[battery] bank soc=80.0 t=1000s") },
                      "expected a battery-tagged SoC line, got: \(live.log)")
    }

    func testBankEmitsNothingWhenBatteryModeOff() {
        UserDefaults.standard.set(false, forKey: "testcentre.active.battery")
        let live = LiveState()
        live.bankBatterySample(80, now: 1000)
        XCTAssertFalse(live.log.contains { $0.contains("[battery]") })
    }
}
