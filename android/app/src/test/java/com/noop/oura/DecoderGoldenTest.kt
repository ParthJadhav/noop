package com.noop.oura

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Golden per-tag fixture tests: raw TLV record bytes -> expected decoded event(s). Kotlin twin of the
 * Swift DecoderGoldenTests.swift.
 *
 * PARITY NOTE: every fixture hex string below is byte-for-byte identical to the Swift
 * DecoderGoldenTests fixtures, so the SAME raw record bytes must decode to the SAME values across the
 * Swift and Kotlin ports (that is the whole point of the twin). Vectors are SYNTHETIC, built from the
 * byte layouts in docs/OURA_PROTOCOL.md s6 (no real biometric capture is embedded). The full record is
 * `type len rt(4 LE) payload` with rt = 0x00010002 (counter 2, session 1) throughout, so every
 * assertion pins ringTimestamp == 65538.
 */
class DecoderGoldenTest {
    private val rt: Long = 0x0001_0002   // 65538
    private val eps = 1e-9

    private fun bytes(s: String) = OuraTestHex.bytes(s)

    /** Parse one record from hex and assert the header decoded as expected. */
    private fun record(hex: String): OuraRecord {
        val rec = OuraFraming.parseRecord(bytes(hex))
            ?: throw AssertionError("record failed to parse: $hex")
        assertEquals(rt, rec.ringTimestamp)
        return rec
    }

    // MARK: - 0x80 green IBI quality (filters on qual; only the good sample passes)

    @Test
    fun testGreenIBIQuality0x80FiltersOnQuality() {
        // body 200b (ibi800, qualA1, qualB0 -> pass) ee42 (ibi750, qualB1 -> reject)
        val rec = record("800802000100200bee42")
        val ibis = OuraDecoders.decodeGreenIBIQuality(rec)
        assertEquals(listOf(OuraIBI(ringTimestamp = rt, ibiMs = 800)), ibis)
    }

    // MARK: - 0x60 IBI + amplitude (MSB-first bit-packed; n=7 -> shift 0)

    @Test
    fun testIBIAmplitude0x60BitPacked() {
        // first pair ibi1000 amp-mantissa64, last byte low nibble = 7 (shift 0).
        val rec = record("6012020001007d10000000000000000000000007")
        val ibis = OuraDecoders.decodeIBIAmplitude(rec)
        assertEquals(OuraIBI(ringTimestamp = rt, ibiMs = 1000, amplitude = 64), ibis?.first())
    }

    // MARK: - 0x6E SpO2 IBI (REVERSE byte order x8)

    @Test
    fun testSpO2IBI0x6EReverseOrder() {
        // body[1..5] = 10,20,30,40,50 read 5->1 reversed -> 50,40,30,20,10 then x8.
        val rec = record("6e0a02000100000a141e2832")
        val ibis = OuraDecoders.decodeSpO2IBI(rec)
        assertEquals(
            listOf(
                OuraIBI(ringTimestamp = rt, ibiMs = 400),
                OuraIBI(ringTimestamp = rt, ibiMs = 320),
                OuraIBI(ringTimestamp = rt, ibiMs = 240),
                OuraIBI(ringTimestamp = rt, ibiMs = 160),
                OuraIBI(ringTimestamp = rt, ibiMs = 80),
            ),
            ibis,
        )
    }

    // MARK: - 0x5D HRV / RMSSD

    @Test
    fun testHRV0x5D() {
        // time 5000, b1=10, b2=-5
        val rec = record("5d080200010088130afb")
        val hrv = OuraDecoders.decodeHRV(rec)
        assertEquals(listOf(OuraHRV(ringTimestamp = rt, timeMs = 5000, b1 = 10, b2 = -5)), hrv)
    }

    // MARK: - 0x6F SpO2 per-sample (base from high nibble << 7, then u8, 0xFF terminator)

    @Test
    fun testSpO2PerSample0x6F() {
        // byte6 high nibble 1 (base/status, discarded) ; samples 95,96 ; FF terminator (#968).
        val rec = record("6f0802000100105f60ff")
        val s = OuraDecoders.decodeSpO2PerSample(rec)
        assertEquals(
            listOf(
                OuraSpO2(ringTimestamp = rt, value = 95),
                OuraSpO2(ringTimestamp = rt, value = 96),
            ),
            s,
        )
    }

    // MARK: - 0x7B SpO2 stable (BIG-endian footgun)

    @Test
    fun testSpO2Stable0x7BIsBigEndian() {
        // BE 0x03CA = 970. If decoded LE it would be 0xCA03 = 51715, so this proves the BE path.
        val rec = record("7b060200010003ca")
        val s = OuraDecoders.decodeSpO2Stable(rec)
        assertEquals(OuraSpO2(ringTimestamp = rt, value = 970), s)
    }

    // MARK: - 0x46 temperature (int16 LE / 100)

    @Test
    fun testTemp0x46() {
        // 3650/100 = 36.50 ; 3655/100 = 36.55
        val rec = record("460802000100420e470e")
        val t = OuraDecoders.decodeTemp(rec)!!
        assertEquals(2, t.size)
        assertEquals(rt, t[0].ringTimestamp)
        assertEquals(36.50, t[0].celsius, eps)
        assertEquals(36.55, t[1].celsius, eps)
    }

    // MARK: - 0x42 time sync (int64 LE epoch ms + tz int8 x1800)

    @Test
    fun testTimeSync0x42() {
        // epoch 1719662400000 ms, tz byte 2 -> 3600 s.
        val rec = record("420d0200010000d2dd639001000002")
        val ts = OuraDecoders.decodeTimeSync(rec)
        assertEquals(OuraTimeSync(ringTimestamp = rt, epochMs = 1_719_662_400_000L, tzOffsetSeconds = 3600), ts)
    }

    // MARK: - 0x4E sleep phase (2-bit codes MSB-first; header byte skipped)

    @Test
    fun testSleepPhase0x4E() {
        // header 0x00, phase byte 0x6C = bits 01 10 11 00 -> light, deep, rem, awake.
        val rec = record("4e0602000100006c")
        val phases = OuraDecoders.decodeSleepPhase(rec)
        assertEquals(
            listOf(
                OuraSleepPhase(ringTimestamp = rt, index = 0, stage = OuraSleepStage.LIGHT),
                OuraSleepPhase(ringTimestamp = rt, index = 1, stage = OuraSleepStage.DEEP),
                OuraSleepPhase(ringTimestamp = rt, index = 2, stage = OuraSleepStage.REM),
                OuraSleepPhase(ringTimestamp = rt, index = 3, stage = OuraSleepStage.AWAKE),
            ),
            phases,
        )
    }

    // MARK: - 0x6B motion period (2-bit MOTION_STATE codes; 2 header bytes skipped)

    @Test
    fun testMotionPeriod0x6B() {
        // 2 header bytes 0x00 0x00, code byte 0x1B = 00 01 10 11 -> noMotion, restless, tossing, active.
        val rec = record("6b070200010000001b")
        val m = OuraDecoders.decodeMotionPeriod(rec)
        assertEquals(
            listOf(
                OuraMotion(ringTimestamp = rt, index = 0, state = OuraMotionState.NO_MOTION),
                OuraMotion(ringTimestamp = rt, index = 1, state = OuraMotionState.RESTLESS),
                OuraMotion(ringTimestamp = rt, index = 2, state = OuraMotionState.TOSSING),
                OuraMotion(ringTimestamp = rt, index = 3, state = OuraMotionState.ACTIVE),
            ),
            m,
        )
    }

    // MARK: - 0x85 RTC beacon (unix_s u32 LE)

    @Test
    fun testRtcBeacon0x85() {
        val rec = record("850e0200010040f77f6600000000f601")
        val r = OuraDecoders.decodeRtcBeacon(rec)
        assertEquals(OuraRtcBeacon(ringTimestamp = rt, unixSeconds = 1_719_662_400L), r)
    }

    // MARK: - 0x45 state change

    @Test
    fun testState0x45() {
        val rec = record("45050200010004")
        val s = OuraDecoders.decodeState(rec)
        assertEquals(4, s?.stateCode)     // user_in_rest
        assertNull(s?.text)               // body too short for a trailing string
    }

    // MARK: - 0x43 debug text

    @Test
    fun testDebugText0x43() {
        val rec = record("4306020001004142")
        assertEquals("AB", OuraDecoders.decodeDebugText(rec))
    }

    // MARK: - 0x0D battery (outer response body; percent at [0], voltage at [4..6] LE)

    @Test
    fun testBattery0x0D() {
        // body: 87%, charging 0, voltage 3900 mv at bytes 4..6.
        val body = bytes("570000003c0f0000")
        val b = OuraDecoders.decodeBattery(body)
        assertEquals(OuraBattery(percent = 87, voltageMv = 3900, charging = false), b)
    }

    @Test
    fun testBatteryRejectsImplausiblePercent() {
        // A "percent" > 100 is a misread; decode to null, never a guessed value.
        val body = intArrayOf(200, 0, 0, 0, 0, 0)
        assertNull(OuraDecoders.decodeBattery(body))
    }

    // MARK: - Live HR push (12-bit nibble IBI -> bpm), built from the s5.6 wire layout

    /**
     * The fixture is derived from the OURA_PROTOCOL.md s5.6 wire frame, NOT from the implementation:
     *   full frame = `2f 0f 28 02 XX 02 00 00 IBI_L IBI_H 00 00 00 00 YY ZZ 7f` (len 0x0f = 15)
     * The transport strips the leading `2f 0f 28`, so the decoder receives the 14-byte subBody with the
     * IBI at subBody[5..6]. Here IBI_L=0x01, IBI_H=0x04 -> ibi ((0x04 & 0x0F)<<8)|0x01 = 1025 ->
     * bpm round(60000/1025) = 59. Byte-for-byte identical to the Swift fixture. Per OURA_PROTOCOL.md s5.6.
     */
    @Test
    fun testLiveHRPushNibbleIBI() {
        val fullFrame = bytes("2f0f28020002000001040000000000007f")
        // Self-check the wire layout: type 0x2f, len 0x0f (15) counts the bytes after type+len, i.e. the
        // subop byte plus the subBody (s2.2). So subBody.size must equal len - 1.
        assertEquals(0x2F, fullFrame[0])
        assertEquals(0x0F, fullFrame[1])
        assertEquals(15, fullFrame[1])
        assertEquals(2 + fullFrame[1], fullFrame.size)          // type + len + 15 body bytes = 17
        // Strip `2f 0f 28` (type, len, subop) exactly as the transport does -> the 14-byte subBody.
        assertArrayEquals(intArrayOf(0x2F, 0x0F, 0x28), fullFrame.copyOfRange(0, 3))
        val subBody = fullFrame.copyOfRange(3, fullFrame.size)
        assertEquals(fullFrame[1] - 1, subBody.size)            // 14 == len(15) - subop(1)
        assertEquals(14, subBody.size)
        // The IBI is at subBody index 5 (low) / 6 (high) per the stripped s5.6 layout.
        assertEquals(0x01, subBody[5])
        assertEquals(0x04, subBody[6])

        val hr = OuraDecoders.decodeLiveHRPush(subBody, rt)
        assertEquals(OuraHR(ringTimestamp = rt, bpm = 59, ibiMs = 1025), hr)
    }

    // MARK: - Honest-data invariant: short / malformed records decode to null

    @Test
    fun testShortRecordsDecodeToNil() {
        // A 0x7B record with a 1-byte payload (needs 2 for the u16) -> null, not a guess.
        val shortSpO2 = OuraRecord(type = 0x7B, ringTimestamp = rt, payload = intArrayOf(0x03))
        assertNull(OuraDecoders.decodeSpO2Stable(shortSpO2))
        // A 0x46 temp with an ODD payload length -> null.
        val oddTemp = OuraRecord(type = 0x46, ringTimestamp = rt, payload = intArrayOf(0x01, 0x02, 0x03))
        assertNull(OuraDecoders.decodeTemp(oddTemp))
        // An empty HRV body -> null.
        assertNull(OuraDecoders.decodeHRV(OuraRecord(type = 0x5D, ringTimestamp = rt, payload = intArrayOf())))
    }
}
