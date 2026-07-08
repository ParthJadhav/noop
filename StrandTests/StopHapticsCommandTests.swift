import XCTest
@testable import Strand
import WhoopProtocol

/// #769: the Breathe / biofeedback teardown clears an in-progress strap haptic pattern with STOP_HAPTICS
/// (cmd 122) so a pattern the strap is mid-way through can't wedge its haptic manager when the link drops.
/// These pin the load-bearing wire facts the fix relies on. The send itself is gated in BLEManager (no-op
/// when not connected, and SKIPPED on a 5/MG since cmd 122 isn't confirmed on its 0x13 path), so this
/// covers the command code + WHOOP 4.0 framing the documented clear stands on.
final class StopHapticsCommandTests: XCTestCase {

    /// STOP_HAPTICS is on-wire command 122 (the documented WHOOP 4.0 stop-haptics opcode).
    func testStopHapticsRawValueIs122() {
        XCTAssertEqual(WhoopCommand.stopHaptics.rawValue, 122)
    }

    /// The WHOOP 4.0 frame: [0xAA][len u16 LE][crc8][type=35][seq][cmd=122][payload=0x00][crc32 LE].
    /// len = inner(type+seq+cmd+payload = 4) + 4 envelope bytes = 8.
    func testStopHapticsFrameShapeWhoop4() {
        let frame = WhoopCommand.stopHaptics.frame(seq: 5, payload: [0x00])
        XCTAssertEqual(frame.first, 0xAA)                 // start of frame
        XCTAssertEqual(frame[1], 8)                       // len low byte (LE)
        XCTAssertEqual(frame[2], 0)                       // len high byte
        XCTAssertEqual(frame[4], WhoopCommand.commandType) // type = 35
        XCTAssertEqual(frame[5], 5)                       // seq
        XCTAssertEqual(frame[6], 122)                     // cmd = STOP_HAPTICS
        XCTAssertEqual(frame[7], 0x00)                    // payload byte
        XCTAssertEqual(frame.count, 12)                   // 1 + 2 + 1 + 4 inner + 4 crc32
    }
}
