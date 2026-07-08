package com.noop.oura

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Framing tests: outer command/response frames, the 0x2F secure-session sub-frame, and the TLV
 * inner-record Reassembler (multi-record-per-notification + partial-trailing-bytes buffering).
 * Kotlin twin of the Swift FramingTests.swift.
 *
 * PARITY NOTE: every fixture hex string here is byte-for-byte identical to the Swift FramingTests
 * fixtures, so the same wire bytes parse + reassemble to the same records across both ports.
 */
class FramingTest {
    private fun bytes(s: String) = OuraTestHex.bytes(s)

    // MARK: - Outer frame

    @Test
    fun testParseOuterFrame() {
        // 0d 06 <6 body bytes> (a battery response shape).
        val f = OuraFraming.parseOuterFrame(bytes("0d06570000003c0f"))
        assertEquals(0x0D, f?.op)
        assertArrayEquals(bytes("570000003c0f"), f?.body)
        assertEquals(8, f?.totalLength)
    }

    @Test
    fun testParseOuterFrameShortReturnsNil() {
        // Declares 6 body bytes but only 2 present -> null (wait for more).
        assertNull(OuraFraming.parseOuterFrame(bytes("0d065700")))
    }

    @Test
    fun testMultipleOuterFramesInOneValue() {
        // 25 01 00  (SetAuthKey resp)  then  1d 01 00 (SetNotification resp).
        val frames = OuraFraming.parseOuterFrames(bytes("2501001d0100"))
        assertEquals(2, frames.size)
        assertEquals(0x25, frames[0].op)
        assertArrayEquals(intArrayOf(0x00), frames[0].body)
        assertEquals(0x1D, frames[1].op)
        assertArrayEquals(intArrayOf(0x00), frames[1].body)
    }

    // MARK: - GetBattery response (0x0D, s6.10)

    @Test
    fun testBatteryResponseOpIsRecognisedAsAnOuterFrame() {
        // 0d 06 <percent=57=87> <charging=00> <flag=00> <3 unknown> - the live path routes this op to the
        // battery decoder, never to the TLV record decoder (op 0x0D is below the event-tag range).
        val frames = OuraFraming.parseOuterFrames(bytes("0d06570000003c0f"))
        assertEquals(1, frames.size)
        assertEquals(OuraFraming.batteryResponseOp, frames[0].op)
        val battery = OuraDecoders.decodeBattery(frames[0].body)
        assertEquals(0x57, battery?.percent)   // 87%
    }

    // MARK: - GetEvents response (0x11, s5.2)

    @Test
    fun testParseGetEventsResponseMoreDataFollows() {
        // 11 08 <status=ff> <sub_status=00> <last_rt:4LE=78563412> <pad:2>
        val outer = OuraFraming.parseOuterFrame(bytes("1108ff00785634120000"))
        assertEquals(OuraFraming.getEventsResponseOp, outer?.op)
        val summary = OuraFraming.parseGetEventsResponse(outer!!.body)
        assertEquals(0x1234_5678L, summary?.cursor)
        assertEquals(true, summary?.moreData)
    }

    @Test
    fun testParseGetEventsResponseNoMoreData() {
        // status 0x00 -> caught up, no more data.
        val outer = OuraFraming.parseOuterFrame(bytes("11080000785634120000"))
        val summary = OuraFraming.parseGetEventsResponse(outer!!.body)
        assertEquals(0x1234_5678L, summary?.cursor)
        assertEquals(false, summary?.moreData)
    }

    @Test
    fun testParseGetEventsResponseShortBodyReturnsNil() {
        assertNull(OuraFraming.parseGetEventsResponse(bytes("ff0012")))
    }

    // MARK: - Secure-session sub-frame (0x2F)

    @Test
    fun testSecureFrameNonceResponse() {
        // Wire: 2f 10 2c <nonce:15>. Outer: op 0x2F, len 0x10 (16), body = 2c + 15 nonce bytes.
        val wire = bytes("2f102c0102030405060708090a0b0c0d0e0f")
        val outer = OuraFraming.parseOuterFrame(wire)!!
        assertEquals(0x2F, outer.op)
        val secure = OuraFraming.parseSecureFrame(outer)!!
        assertEquals(0x2C, secure.subop)
        assertArrayEquals(bytes("0102030405060708090a0b0c0d0e0f"), secure.subBody)
        // And the auth layer pulls the 15-byte nonce straight out.
        assertArrayEquals(bytes("0102030405060708090a0b0c0d0e0f"), OuraAuth.nonce(secure))
    }

    @Test
    fun testSecureFrameAuthStatus() {
        // 2f 02 2e 00 -> success.
        val wire = bytes("2f022e00")
        val outer = OuraFraming.parseOuterFrame(wire)!!
        val secure = OuraFraming.parseSecureFrame(outer)!!
        assertEquals(0x2E, secure.subop)
        assertEquals(OuraAuthStatus.SUCCESS, OuraAuth.authStatus(secure))
    }

    @Test
    fun testNonSecureFrameReturnsNilSecure() {
        val outer = OuraOuterFrame(op = 0x0D, body = intArrayOf(0x01))
        assertNull(OuraFraming.parseSecureFrame(outer))
    }

    // MARK: - TLV record parsing

    @Test
    fun testParseTLVRecord() {
        // 7b 06 <rt:4 LE 02000100> 03 ca  -> type 0x7B, rt 0x00010002, payload 03 ca.
        val rec = OuraFraming.parseRecord(bytes("7b060200010003ca"))
        assertEquals(0x7B, rec?.type)
        assertEquals(0x0001_0002L, rec?.ringTimestamp)
        assertEquals(0x0002, rec?.counter)
        assertEquals(0x0001, rec?.session)
        assertArrayEquals(bytes("03ca"), rec?.payload)
        assertEquals(8, rec?.totalLength)
    }

    @Test
    fun testTLVLenBelowFourIsRejected() {
        // len must be >= 4 to cover the 4 timestamp bytes; len=3 -> null (honest, no guess).
        assertNull(OuraFraming.parseRecord(intArrayOf(0x7B, 0x03, 0x00, 0x01, 0x02)))
    }

    // MARK: - Reassembler: multiple records per notification

    @Test
    fun testReassemblerMultipleRecordsInOneNotification() {
        // Two complete records packed into one notification value.
        val r = OuraReassembler()
        val recs = r.feed(bytes("7b060200010003ca" + "4e0602000100006c"))
        assertEquals(2, recs.size)
        assertEquals(0x7B, recs[0].type)
        assertEquals(0x4E, recs[1].type)
        assertEquals(0, r.bufferedByteCount)
    }

    // MARK: - Reassembler: partial trailing bytes buffered across notifications

    @Test
    fun testReassemblerPartialTrailingBytesBuffered() {
        val full = bytes("7b060200010003ca")   // one complete 8-byte record
        val r = OuraReassembler()
        // Feed only the first 5 bytes -> nothing complete yet, the rest is buffered.
        assertTrue(r.feed(full.copyOfRange(0, 5)).isEmpty())
        assertEquals(5, r.bufferedByteCount)
        // Feed the remaining 3 bytes -> the record now completes.
        val recs = r.feed(full.copyOfRange(5, full.size))
        assertEquals(1, recs.size)
        assertEquals(0x7B, recs[0].type)
        assertEquals(0, r.bufferedByteCount)
    }

    @Test
    fun testReassemblerSplitAcrossThreeFragments() {
        // A record split byte-by-byte still reassembles, and a second record packed behind it emerges.
        val recHex = "4e0602000100006c"          // 8 bytes
        val trailing = "7b060200010003ca"         // 8 bytes
        val all = bytes(recHex + trailing)
        val r = OuraReassembler()
        val out = ArrayList<OuraRecord>()
        // Feed in 3-byte chunks.
        var i = 0
        while (i < all.size) {
            out.addAll(r.feed(all.copyOfRange(i, minOf(i + 3, all.size))))
            i += 3
        }
        assertArrayEquals(intArrayOf(0x4E, 0x7B), out.map { it.type }.toIntArray())
    }

    @Test
    fun testReassemblerResetClearsBuffer() {
        val r = OuraReassembler()
        r.feed(intArrayOf(0x7B, 0x06, 0x02))   // partial
        assertTrue(r.bufferedByteCount > 0)
        r.reset()
        assertEquals(0, r.bufferedByteCount)
    }

    @Test
    fun testReassemblerDrainsPureNoiseWithoutEmittingOrWedging() {
        // The TLV format has NO start-of-frame marker, so a stream of bytes whose len field is < 4
        // cannot be realigned to an arbitrary later record (unlike WHOOP's 0xAA SOF). The len < 4
        // guard's job is narrower but important: never EMIT a garbage record, and never WEDGE waiting
        // for bytes that cannot complete. A pure-noise burst drains to a tiny tail with no emissions.
        val r = OuraReassembler()
        val recs = r.feed(intArrayOf(0x00, 0x01, 0x02, 0x03, 0x01, 0x02))   // every len field < 4
        assertTrue("noise must not produce false records", recs.isEmpty())
        assertTrue("noise must drain, not accumulate forever", r.bufferedByteCount <= 1)
    }

    @Test
    fun testReassemblerLenBelowFourDoesNotEmitGarbageBeforeValidRecord() {
        // A 2-byte garbage header whose len is < 4 is dropped one byte at a time; because TLV has no
        // SOF this does not realign to the trailing valid record, but it must NOT emit a bogus record.
        val valid = bytes("4e0602000100006c")
        val r = OuraReassembler()
        val recs = r.feed(intArrayOf(0x00, 0x01) + valid)   // 00 01 = len 1 (< 4)
        assertTrue("must never emit a type-0 garbage record", recs.all { it.type != 0x00 })
    }
}
