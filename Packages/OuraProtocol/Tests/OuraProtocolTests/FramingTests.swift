import XCTest
@testable import OuraProtocol

/// Framing tests: outer command/response frames, the 0x2F secure-session sub-frame, and the TLV
/// inner-record Reassembler (multi-record-per-notification + partial-trailing-bytes buffering).
final class FramingTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // MARK: - Outer frame

    func testParseOuterFrame() {
        // 0d 06 <6 body bytes> (a battery response shape).
        let f = OuraFraming.parseOuterFrame(bytes("0d06570000003c0f"))
        XCTAssertEqual(f?.op, 0x0D)
        XCTAssertEqual(f?.body, bytes("570000003c0f"))
        XCTAssertEqual(f?.totalLength, 8)
    }

    func testParseOuterFrameShortReturnsNil() {
        // Declares 6 body bytes but only 2 present -> nil (wait for more).
        XCTAssertNil(OuraFraming.parseOuterFrame(bytes("0d065700")))
    }

    func testMultipleOuterFramesInOneValue() {
        // 25 01 00  (SetAuthKey resp)  then  1d 01 00 (SetNotification resp).
        let frames = OuraFraming.parseOuterFrames(bytes("2501001d0100"))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].op, 0x25)
        XCTAssertEqual(frames[0].body, [0x00])
        XCTAssertEqual(frames[1].op, 0x1D)
        XCTAssertEqual(frames[1].body, [0x00])
    }

    // MARK: - GetBattery response (0x0D, s6.10)

    func testBatteryResponseOpIsRecognisedAsAnOuterFrame() {
        // 0d 06 <percent=57=87> <charging=00> <flag=00> <3 unknown> - the live path routes this op to the
        // battery decoder, never to the TLV record decoder (op 0x0D is below the event-tag range).
        let frames = OuraFraming.parseOuterFrames(bytes("0d06570000003c0f"))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].op, OuraFraming.batteryResponseOp)
        let battery = OuraDecoders.decodeBattery(frames[0].body)
        XCTAssertEqual(battery?.percent, 0x57)   // 87%
    }

    // MARK: - GetEvents response (0x11, s5.2)

    func testParseGetEventsResponseMoreDataFollows() {
        // 11 08 <status=ff> <sub_status=00> <last_rt:4LE=78563412> <pad:2>
        let outer = OuraFraming.parseOuterFrame(bytes("1108ff00785634120000"))
        XCTAssertEqual(outer?.op, OuraFraming.getEventsResponseOp)
        let summary = OuraFraming.parseGetEventsResponse(outer!.body)
        XCTAssertEqual(summary?.cursor, 0x1234_5678)
        XCTAssertEqual(summary?.moreData, true)
    }

    func testParseGetEventsResponseNoMoreData() {
        // status 0x00 -> caught up, no more data.
        let outer = OuraFraming.parseOuterFrame(bytes("11080000785634120000"))
        let summary = OuraFraming.parseGetEventsResponse(outer!.body)
        XCTAssertEqual(summary?.cursor, 0x1234_5678)
        XCTAssertEqual(summary?.moreData, false)
    }

    func testParseGetEventsResponseShortBodyReturnsNil() {
        XCTAssertNil(OuraFraming.parseGetEventsResponse(bytes("ff0012")))
    }

    // MARK: - Secure-session sub-frame (0x2F)

    func testSecureFrameNonceResponse() {
        // Wire: 2f 10 2c <nonce:15>. Outer: op 0x2F, len 0x10 (16), body = 2c + 15 nonce bytes.
        let wire = bytes("2f102c0102030405060708090a0b0c0d0e0f")
        guard let outer = OuraFraming.parseOuterFrame(wire) else { return XCTFail("outer parse") }
        XCTAssertEqual(outer.op, 0x2F)
        guard let secure = OuraFraming.parseSecureFrame(outer) else { return XCTFail("secure parse") }
        XCTAssertEqual(secure.subop, 0x2C)
        XCTAssertEqual(secure.subBody, bytes("0102030405060708090a0b0c0d0e0f"))
        // And the auth layer pulls the 15-byte nonce straight out.
        XCTAssertEqual(OuraAuth.nonce(from: secure), bytes("0102030405060708090a0b0c0d0e0f"))
    }

    func testSecureFrameAuthStatus() {
        // 2f 02 2e 00 -> success.
        let wire = bytes("2f022e00")
        guard let outer = OuraFraming.parseOuterFrame(wire),
              let secure = OuraFraming.parseSecureFrame(outer) else { return XCTFail("parse") }
        XCTAssertEqual(secure.subop, 0x2E)
        XCTAssertEqual(OuraAuth.authStatus(from: secure), .success)
    }

    func testNonSecureFrameReturnsNilSecure() {
        let outer = OuraOuterFrame(op: 0x0D, body: [0x01])
        XCTAssertNil(OuraFraming.parseSecureFrame(outer))
    }

    // MARK: - TLV record parsing

    func testParseTLVRecord() {
        // 7b 06 <rt:4 LE 02000100> 03 ca  -> type 0x7B, rt 0x00010002, payload 03 ca.
        let rec = OuraFraming.parseRecord(bytes("7b060200010003ca"))
        XCTAssertEqual(rec?.type, 0x7B)
        XCTAssertEqual(rec?.ringTimestamp, 0x0001_0002)
        XCTAssertEqual(rec?.counter, 0x0002)
        XCTAssertEqual(rec?.session, 0x0001)
        XCTAssertEqual(rec?.payload, bytes("03ca"))
        XCTAssertEqual(rec?.totalLength, 8)
    }

    func testTLVLenBelowFourIsRejected() {
        // len must be >= 4 to cover the 4 timestamp bytes; len=3 -> nil (honest, no guess).
        XCTAssertNil(OuraFraming.parseRecord([0x7B, 0x03, 0x00, 0x01, 0x02]))
    }

    // MARK: - Reassembler: multiple records per notification

    func testReassemblerMultipleRecordsInOneNotification() {
        // Two complete records packed into one notification value.
        let r = OuraReassembler()
        let recs = r.feed(bytes("7b060200010003ca" + "4e0602000100006c"))
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(recs[0].type, 0x7B)
        XCTAssertEqual(recs[1].type, 0x4E)
        XCTAssertEqual(r.bufferedByteCount, 0)
    }

    // MARK: - Reassembler: partial trailing bytes buffered across notifications

    func testReassemblerPartialTrailingBytesBuffered() {
        let full = bytes("7b060200010003ca")   // one complete 8-byte record
        let r = OuraReassembler()
        // Feed only the first 5 bytes -> nothing complete yet, the rest is buffered.
        XCTAssertTrue(r.feed(Array(full[0..<5])).isEmpty)
        XCTAssertEqual(r.bufferedByteCount, 5)
        // Feed the remaining 3 bytes -> the record now completes.
        let recs = r.feed(Array(full[5...]))
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].type, 0x7B)
        XCTAssertEqual(r.bufferedByteCount, 0)
    }

    func testReassemblerSplitAcrossThreeFragments() {
        // A record split byte-by-byte still reassembles, and a second record packed behind it emerges.
        let recHex = "4e0602000100006c"          // 8 bytes
        let trailing = "7b060200010003ca"         // 8 bytes
        let all = bytes(recHex + trailing)
        let r = OuraReassembler()
        var out: [OuraRecord] = []
        // Feed in 3-byte chunks.
        var i = 0
        while i < all.count {
            out.append(contentsOf: r.feed(Array(all[i..<min(i + 3, all.count)])))
            i += 3
        }
        XCTAssertEqual(out.map { $0.type }, [0x4E, 0x7B])
    }

    func testReassemblerResetClearsBuffer() {
        let r = OuraReassembler()
        _ = r.feed([0x7B, 0x06, 0x02])   // partial
        XCTAssertGreaterThan(r.bufferedByteCount, 0)
        r.reset()
        XCTAssertEqual(r.bufferedByteCount, 0)
    }

    func testReassemblerDrainsPureNoiseWithoutEmittingOrWedging() {
        // The TLV format has NO start-of-frame marker, so a stream of bytes whose len field is < 4
        // cannot be realigned to an arbitrary later record (unlike WHOOP's 0xAA SOF). The len < 4
        // guard's job is narrower but important: never EMIT a garbage record, and never WEDGE waiting
        // for bytes that cannot complete. A pure-noise burst drains to a tiny tail with no emissions.
        let r = OuraReassembler()
        let recs = r.feed([0x00, 0x01, 0x02, 0x03, 0x01, 0x02])   // every len field < 4
        XCTAssertTrue(recs.isEmpty, "noise must not produce false records")
        XCTAssertLessThanOrEqual(r.bufferedByteCount, 1, "noise must drain, not accumulate forever")
    }

    func testReassemblerLenBelowFourDoesNotEmitGarbageBeforeValidRecord() {
        // A 2-byte garbage header whose len is < 4 is dropped one byte at a time; because TLV has no
        // SOF this does not realign to the trailing valid record, but it must NOT emit a bogus record.
        let valid = bytes("4e0602000100006c")
        let r = OuraReassembler()
        let recs = r.feed([0x00, 0x01] + valid)   // 00 01 = len 1 (< 4)
        XCTAssertTrue(recs.allSatisfy { $0.type != 0x00 }, "must never emit a type-0 garbage record")
    }
}
