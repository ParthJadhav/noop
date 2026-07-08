import XCTest
@testable import WhoopProtocol

final class InterpreterEnvelopeTests: XCTestCase {
    static func hex(_ s: String) -> [UInt8] { FramingTests.hex(s) }

    func testRealtimeDataEnvelopeAndStaticFields() {
        let frame = Self.hex("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        // collectFields: this test asserts on the annotated fields array, which is opt-in
        // diagnostics (D#742). FastPathParityTests pins the default fast path.
        let out = parseFrame(frame, collectFields: true)
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.typeName, "REALTIME_DATA")
        XCTAssertEqual(out.seq, 2)
        XCTAssertEqual(out.crcOK, true)
        XCTAssertNil(out.cmdName) // type 40 is not 35/36
        XCTAssertEqual(out.lenBytes, frame.count)
        XCTAssertEqual(out.rawHex, "aa1800ff28020f3de10128663c0000000000000000000000da855212")
        // static fields (post-hook adds rr_intervals later; here just the schema fields):
        XCTAssertEqual(out.parsed["timestamp"], .int(31538447))
        XCTAssertEqual(out.parsed["subseconds"], .int(26152))
        XCTAssertEqual(out.parsed["heart_rate"], .int(60))
        XCTAssertEqual(out.parsed["rr_count"], .int(0))
        // envelope fields exist but are cat "frame" so excluded from parsed:
        XCTAssertNil(out.parsed["SOF"])
        XCTAssertNil(out.parsed["length"])
        XCTAssertNotNil(out.fields.first { $0.name == "packet_type" })
        // crc32 trailer field present
        XCTAssertNotNil(out.fields.first { $0.name == "crc32" })
    }

    func testCommandResponseCmdName() {
        let frame = Self.hex("aa10005724241a0000ff000000000000ac811df4")
        let out = parseFrame(frame)
        XCTAssertEqual(out.typeName, "COMMAND_RESPONSE")
        XCTAssertEqual(out.cmdName, "GET_BATTERY_LEVEL(26)")
        // resp_cmd static field is enum-formatted
        XCTAssertEqual(out.parsed["resp_cmd"], .string("GET_BATTERY_LEVEL(26)"))
    }

    func testInvalidFrame() {
        // collectFields:true so rawHex is populated (D#969 gates rawHex on collectFields).
        let out = parseFrame([0x01, 0x02], collectFields: true)
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.typeName, "INVALID/FRAGMENT")
        XCTAssertEqual(out.rawHex, "0102")
        XCTAssertEqual(out.lenBytes, 2)
        XCTAssertTrue(out.parsed.isEmpty)
    }

    func testUnknownPacketTypeFallsBack() {
        // Build a valid frame with an unknown type byte (200), 2 payload bytes.
        let frame = frameFromPayload([0xAB, 0xCD], type: 200, seq: 9, cmd: 5)
        let out = parseFrame(frame)
        XCTAssertEqual(out.typeName, "type200")
        XCTAssertEqual(out.seq, 9)
        // no spec -> cmd field + payload region; cmd cat is "cmd" so it lands in parsed.
        XCTAssertEqual(out.parsed["cmd"], .int(5))
    }
}
