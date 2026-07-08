import XCTest
import StrandAnalytics
@testable import Strand

/// Wiring of the discharge-run / slope / gate trace into the live path: banking the charge-step fixture
/// and calling emitBatteryTrace() lands the slope + gate lines, tagged .battery, when the mode is on
/// (#713, Test Centre). No em-dashes.
@MainActor
final class BatteryEstimateTraceEmitTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "testcentre.active.battery")
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "testcentre.active.battery")
        super.tearDown()
    }

    func testEmitBatteryTraceWritesSlopeAndGateLines() {
        let live = LiveState()
        let h = 3600
        live.bankBatterySample(100, now: 0)
        live.bankBatterySample(70, now: 4 * h)
        live.bankBatterySample(100, now: 5 * h)
        live.bankBatterySample(88, now: 11 * h)
        live.emitBatteryTrace()
        XCTAssertTrue(live.log.contains { $0.contains("[battery] battery slope=2.0pct/h fitted from run endpoints") })
        XCTAssertTrue(live.log.contains { $0.contains("[battery] battery gate minSpanHours 2.0 PASS, minDropPct 2.0 PASS -> source=measured") })
    }

    func testEmitBatteryTraceIsNoOpWhenModeOff() {
        UserDefaults.standard.set(false, forKey: "testcentre.active.battery")
        let live = LiveState()
        live.bankBatterySample(100, now: 0)
        live.bankBatterySample(80, now: 10 * 3600)
        live.emitBatteryTrace()
        XCTAssertFalse(live.log.contains { $0.contains("[battery]") })
    }
}
