import XCTest
@testable import Strand

/// Pins the WHOOP 4.0 SET_ALARM_TIME (cmd 66) payload byte-for-byte.
///
/// The earlier 7-byte form (`[0x01] + u32 LE epoch + [0x00, 0x00]`) made the strap ACK and log
/// "armed" but never buzz (#428: no STRAP_DRIVEN_ALARM_EXECUTED event). @ujix's btsnoop capture of
/// the official WHOOP app on a real 4.0 (PR #535) showed the official app always sends 9 bytes — the
/// missing trailing `[0x00, 0x00]` is a haptic-mode field. We now send the same 9 bytes; these tests
/// pin that layout so the field can never silently regress to the silent 7-byte form again.
///
/// NOTE: the buzz is confirmed on-device by the capture author (PR #535, 2026-06-20): a real WHOOP 4.0
/// buzzes at the specified time with this 9-byte frame. These tests pin the bytes we send; they do not
/// assert the strap wakes.
final class SetAlarmPayloadTests: XCTestCase {

    func testLength_isNineBytes() {
        XCTAssertEqual(WhoopCommand.setAlarmPayload(epochSec: 0).count, 9,
                       "official app sends 9 bytes — the 7-byte form never buzzed (#535)")
    }

    func testLeadingByte_isFormByte0x01() {
        XCTAssertEqual(WhoopCommand.setAlarmPayload(epochSec: 0)[0], 0x01)
    }

    func testEpochField_isU32LittleEndian() {
        // 0x11223344 → LE: 0x44, 0x33, 0x22, 0x11
        let p = WhoopCommand.setAlarmPayload(epochSec: 0x1122_3344)
        XCTAssertEqual(Array(p[1..<5]), [0x44, 0x33, 0x22, 0x11], "u32 LE epoch")
    }

    func testSubsecondsField_isAlwaysZero() {
        let p = WhoopCommand.setAlarmPayload(epochSec: 1_781_912_880)
        XCTAssertEqual(Array(p[5..<7]), [0x00, 0x00], "subseconds (minute precision)")
    }

    func testHapticModeField_isAlwaysZero() {
        let p = WhoopCommand.setAlarmPayload(epochSec: 1_781_912_880)
        XCTAssertEqual(Array(p[7..<9]), [0x00, 0x00], "haptic-mode field (the missing 2 bytes, #535)")
    }

    /// Whole-frame check against the captured epoch from @ujix's btsnoop log (PR #535).
    /// 1781912880 = 0x6A35D530 → LE: 0x30, 0xD5, 0x35, 0x6A.
    func testWireCapture_epoch1781912880_matchesOfficialApp() {
        XCTAssertEqual(
            WhoopCommand.setAlarmPayload(epochSec: 1_781_912_880),
            [0x01, 0x30, 0xD5, 0x35, 0x6A, 0x00, 0x00, 0x00, 0x00]
        )
    }

    /// The max epoch still serialises to exactly four LE bytes (no overflow past the 9-byte frame).
    func testMaxEpoch_staysNineBytes() {
        let p = WhoopCommand.setAlarmPayload(epochSec: .max)
        XCTAssertEqual(p.count, 9)
        XCTAssertEqual(Array(p[1..<5]), [0xFF, 0xFF, 0xFF, 0xFF])
    }
}
