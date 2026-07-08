import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// Proves the Connection & Sync test mode (Test Centre) is GENUINELY zero-cost when off: the frame-timing
/// emitter in FrameRouter is gated behind TestCentre.active(.connection), so with the mode OFF a handled
/// frame writes ZERO .connection-tagged lines, and with it ON it writes exactly one per frame-type
/// transition. The CRITICAL property the spec calls out is the mode-off path emitting nothing tagged.
@MainActor
final class ConnectionTestModeEmissionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The gate reads UserDefaults.standard; make sure the connection mode starts OFF (and master off).
        UserDefaults.standard.removeObject(forKey: "testcentre.active.connection")
        UserDefaults.standard.removeObject(forKey: "testcentre.active.master")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "testcentre.active.connection")
        UserDefaults.standard.removeObject(forKey: "testcentre.active.master")
        super.tearDown()
    }

    // A valid REALTIME_DATA (type 40) frame: parses ok with a non-nil typeName, so FrameRouter reaches the
    // frame-type-transition branch where the .connection emitter lives.
    private func realtimeFrame() -> [UInt8] {
        frameFromPayload([0x01, 0x02, 0x03], type: 40, seq: 0, cmd: 0)
    }

    private func connectionLines(_ live: LiveState) -> [String] {
        live.taggedTail(domain: .connection)
    }

    func testModeOffEmitsZeroConnectionLines() {
        XCTAssertFalse(TestCentre.active(.connection))   // precondition: mode is off
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.handle(frame: realtimeFrame())
        XCTAssertTrue(connectionLines(live).isEmpty,
                      "mode OFF must emit zero .connection lines, got \(connectionLines(live))")
    }

    func testModeOnEmitsAFrameTimingLine() {
        TestCentre.activate(.connection)
        defer { TestCentre.deactivate(.connection) }
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.handle(frame: realtimeFrame())
        let lines = connectionLines(live)
        XCTAssertEqual(lines.count, 1, "one tagged frame-timing line per type transition, got \(lines)")
        XCTAssertTrue(lines.first?.contains("frameTiming type=") ?? false, lines.first ?? "nil")
    }

    // The change-guard throttle: re-handling the SAME frame type does NOT emit a second line (the raw
    // flood would otherwise spam the log). Only a genuine type transition emits.
    func testRepeatedSameTypeDoesNotReEmit() {
        TestCentre.activate(.connection)
        defer { TestCentre.deactivate(.connection) }
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.handle(frame: realtimeFrame())
        router.handle(frame: realtimeFrame())   // same type → no second emit
        XCTAssertEqual(connectionLines(live).count, 1, "the type-transition guard must throttle the flood")
    }
}
