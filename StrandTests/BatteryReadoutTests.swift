import XCTest
import StrandAnalytics
@testable import Strand

/// The Battery live-readout resolver: maps the registry's three liveReadout ids to short display strings
/// bound directly to LiveState's banked battery state, returning "--" when there is no estimate yet
/// (#713, Test Centre). No em-dashes.
@MainActor
final class BatteryReadoutTests: XCTestCase {

    func testReadoutResolvesCurrentSocDaysLeftAndSlopeSource() {
        let live = LiveState()
        let h = 3600
        live.bankBatterySample(100, now: 0)
        live.bankBatterySample(90, now: 10 * h)   // 1 %/h measured, 90% -> 90h -> 3.8 days
        XCTAssertEqual(live.batteryReadout("currentSoc"), "90%")
        XCTAssertEqual(live.batteryReadout("estimateDaysLeft"), "~3.8 days")
        XCTAssertEqual(live.batteryReadout("slopeSource"), "measured")
    }

    func testReadoutUnknownIdIsDash() {
        let live = LiveState()
        XCTAssertEqual(live.batteryReadout("currentSoc"), "--")
        XCTAssertEqual(live.batteryReadout("nope"), "--")
    }
}
