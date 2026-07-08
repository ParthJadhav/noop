import XCTest
import WhoopProtocol
@testable import Strand

/// Pins the WHOOP 4.0 GET_ALARM_TIME (cmd 67) arm-readback decode (#401 close-out).
///
/// armStrapAlarm follows every 4.0 arm with GET_ALARM_TIME so the strap log proves what the STRAP
/// believes is armed. The response layout is UNDOCUMENTED, so `FrameRouter.armedAlarmEpoch` is
/// deliberately defensive: it accepts the SET_ALARM_TIME-mirror shape (`[form 0x01][u32 LE epoch]…`)
/// or a bare leading u32 LE, plausibility-gated to a real wall-clock window; everything else decodes
/// to nil and the router logs raw hex instead. These tests pin BOTH the accepted shapes and the
/// fail-to-hex behaviour so a firmware variant can never silently log a misleading date.
final class AlarmReadbackDecodeTests: XCTestCase {

    /// Build a synthetic WHOOP 4.0 COMMAND_RESPONSE frame around `payload`:
    /// `[0xAA][len u16 LE][crc8][type=36][seq][cmd][origin_seq][result][payload…][crc32 x4]`.
    /// `len` marks where the crc32 trailer starts, exactly as `WhoopCommand.frame` lays it out. The
    /// decode helpers never check CRCs (parseFrame does that on the live path before the router runs),
    /// so fixed filler bytes stand in for crc8/crc32 here.
    private func responseFrame(cmd: UInt8 = 67, result: UInt8 = 1, payload: [UInt8]) -> [UInt8] {
        let inner: [UInt8] = [36, 0x29, cmd, 0x42, result] + payload
        let length = UInt16(inner.count + 4)
        return [0xAA, UInt8(length & 0xFF), UInt8(length >> 8), 0x57] + inner + [0xDE, 0xAD, 0xBE, 0xEF]
    }

    /// The SET-mirror shape, using the #535 capture epoch (1781912880 = 0x6A35D530 → LE 30 D5 35 6A):
    /// a strap echoing back the exact 9-byte payload we armed with decodes to that epoch.
    func testSetMirrorPayload_decodesCaptureEpoch() {
        let frame = responseFrame(payload: [0x01, 0x30, 0xD5, 0x35, 0x6A, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(FrameRouter.armedAlarmEpoch(in: frame), 1_781_912_880)
    }

    /// A bare leading u32 LE (no form byte) is the other plausible firmware answer; same epoch decodes.
    func testBareU32Payload_decodesCaptureEpoch() {
        let frame = responseFrame(payload: [0x30, 0xD5, 0x35, 0x6A])
        XCTAssertEqual(FrameRouter.armedAlarmEpoch(in: frame), 1_781_912_880)
    }

    /// The SET-mirror form wins over the bare read: a payload whose form byte is 0x01 decodes from
    /// offset 1, never from offset 0 (offset 0 would misread the form byte into the epoch). Bytes
    /// chosen so BOTH offsets yield plausible epochs - offset 1 reads 0x685E0060 = 1750990944
    /// (2025), offset 0 would read 0x5E000060|0x01 = 1577082881 (2019) - so this genuinely pins the
    /// precedence, not just the happy path.
    func testSetMirrorForm_takesPrecedenceOverBareRead() {
        let frame = responseFrame(payload: [0x01, 0x60, 0x00, 0x5E, 0x68])
        XCTAssertEqual(FrameRouter.armedAlarmEpoch(in: frame), 1_750_990_944)
    }

    /// A result-style single byte (e.g. an UNSUPPORTED echo) must not decode; the router falls back to
    /// the raw-hex line.
    func testShortGarbagePayload_decodesNil() {
        let frame = responseFrame(payload: [0x03])
        XCTAssertNil(FrameRouter.armedAlarmEpoch(in: frame))
    }

    /// An implausible epoch (5 = 1970) is a disarmed/garbage answer, not an armed alarm - nil, raw hex.
    func testImplausibleEpoch_decodesNil() {
        let frame = responseFrame(payload: [0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertNil(FrameRouter.armedAlarmEpoch(in: frame))
    }

    /// An empty payload (header-only response) decodes nil and yields no hex either.
    func testEmptyPayload_decodesNilAndNoHex() {
        let frame = responseFrame(payload: [])
        XCTAssertNil(FrameRouter.armedAlarmEpoch(in: frame))
        XCTAssertNil(FrameRouter.commandResponsePayloadHex(in: frame))
    }

    /// A truncated frame (shorter than its declared length) must decode nil, never read out of bounds.
    func testTruncatedFrame_decodesNil() {
        var frame = responseFrame(payload: [0x01, 0x30, 0xD5, 0x35, 0x6A, 0x00, 0x00, 0x00, 0x00])
        frame.removeLast(10)
        XCTAssertNil(FrameRouter.armedAlarmEpoch(in: frame))
    }

    /// The raw-hex fallback renders the payload bytes space-separated lowercase, exactly the payload
    /// (no envelope, no crc32), so a report reader sees the strap's answer verbatim.
    func testPayloadHexFallback_rendersPayloadBytes() {
        let frame = responseFrame(payload: [0x03, 0xAB])
        XCTAssertEqual(FrameRouter.commandResponsePayloadHex(in: frame), "03 ab")
    }

    /// Pins the plausibility window bounds (2017..2100, inclusive) so a tweak can't silently widen it.
    func testPlausibilityBounds() {
        XCTAssertTrue(FrameRouter.isPlausibleAlarmEpoch(1_500_000_000))
        XCTAssertFalse(FrameRouter.isPlausibleAlarmEpoch(1_499_999_999))
        XCTAssertTrue(FrameRouter.isPlausibleAlarmEpoch(4_102_444_800))
        XCTAssertFalse(FrameRouter.isPlausibleAlarmEpoch(4_102_444_801))
    }

    // MARK: - Dispatch (handle) coverage

    /// Build a crc32-valid WHOOP 4.0 COMMAND_RESPONSE (type 36) that parseFrame accepts, carrying the
    /// GET_ALARM_TIME cmd byte (67) and the given readback payload. frameFromPayload lays out
    /// [0xAA][len][crc8][type][seq][cmd][data…][crc32] with a real crc32, so handle() will not reject it
    /// on the crcOK gate. `data` is [origin_seq, result, payload…], matching the inner walk the decode
    /// helpers use.
    @MainActor
    private func alarmResponseFrame(cmd: UInt8 = 67, payload: [UInt8]) -> [UInt8] {
        frameFromPayload([0x42, 0x01] + payload, type: 36, seq: 0x29, cmd: cmd)
    }

    /// The dispatch regression the ship-blocker fixed: cmdName is "GET_ALARM_TIME(67)" (Schema.enumName
    /// appends the "(rawValue)" suffix), so an equality compare against "GET_ALARM_TIME" was dead code and
    /// nothing ever logged. With hasPrefix matching, a synthesized readback frame now fires the branch and
    /// writes the "strap reports armed" line - proving the branch is reachable, not just the pure decode.
    @MainActor
    func testHandle_alarmReadbackFrame_logsStrapReports() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.family = .whoop4
        // SET-mirror payload with the #535 capture epoch (1781912880 = LE 30 D5 35 6A).
        router.handle(frame: alarmResponseFrame(payload: [0x01, 0x30, 0xD5, 0x35, 0x6A, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertTrue(live.log.contains { $0.contains("strap reports armed") && $0.contains("1781912880") },
                      "GET_ALARM_TIME readback branch must fire via handle(): \(live.log)")
    }

    /// An unrecognised readback payload still fires the branch and logs the raw-hex fallback, proving the
    /// else arm is reachable too (not just the happy path).
    @MainActor
    func testHandle_unrecognisedReadbackPayload_logsRawHex() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.family = .whoop4
        router.handle(frame: alarmResponseFrame(payload: [0x03, 0xAB]))
        XCTAssertTrue(live.log.contains { $0.contains("unrecognised payload") && $0.contains("03 ab") },
                      "unrecognised readback must log raw hex via handle(): \(live.log)")
    }
}
