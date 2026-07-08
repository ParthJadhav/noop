package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the WHOOP 4.0 GET_ALARM_TIME (cmd 67) arm-readback decode (#401 close-out), twin of the Swift
 * `AlarmReadbackDecodeTests`.
 *
 * armStrapAlarm follows every 4.0 arm with GET_ALARM_TIME so the strap log proves what the STRAP
 * believes is armed. The response layout is UNDOCUMENTED, so [whoop4ArmedAlarmEpoch] is deliberately
 * defensive: it accepts the SET_ALARM_TIME-mirror shape (`[form 0x01][u32 LE epoch]…`) or a bare
 * leading u32 LE, plausibility-gated to a real wall-clock window; everything else decodes to null and
 * handleFrame logs raw hex instead. These tests pin BOTH the accepted shapes and the fail-to-hex
 * behaviour so a firmware variant can never silently log a misleading date.
 */
class AlarmReadbackDecodeTest {

    private fun bytes(vararg ints: Int): ByteArray = ByteArray(ints.size) { ints[it].toByte() }

    /**
     * Build a synthetic WHOOP 4.0 COMMAND_RESPONSE frame around [payload]:
     * `[0xAA][len u16 LE][crc8][type=36][seq][cmd][origin_seq][result][payload…][crc32 x4]`.
     * `len` marks where the crc32 trailer starts, exactly as Framing lays it out. The decode helpers
     * never check CRCs (the parser does that on the live path), so fixed filler bytes stand in.
     */
    private fun responseFrame(cmd: Int = 67, result: Int = 1, payload: ByteArray): ByteArray {
        val inner = bytes(36, 0x29, cmd, 0x42, result) + payload
        val length = inner.size + 4
        return bytes(0xAA, length and 0xFF, (length shr 8) and 0xFF, 0x57) + inner +
            bytes(0xDE, 0xAD, 0xBE, 0xEF)
    }

    /** The SET-mirror shape, using the #535 capture epoch (1781912880 = 0x6A35D530 → LE 30 D5 35 6A). */
    @Test
    fun setMirrorPayload_decodesCaptureEpoch() {
        val frame = responseFrame(payload = bytes(0x01, 0x30, 0xD5, 0x35, 0x6A, 0x00, 0x00, 0x00, 0x00))
        assertEquals(1_781_912_880L, whoop4ArmedAlarmEpoch(frame))
    }

    /** A bare leading u32 LE (no form byte) is the other plausible firmware answer. */
    @Test
    fun bareU32Payload_decodesCaptureEpoch() {
        val frame = responseFrame(payload = bytes(0x30, 0xD5, 0x35, 0x6A))
        assertEquals(1_781_912_880L, whoop4ArmedAlarmEpoch(frame))
    }

    /**
     * The SET-mirror form wins over the bare read. Bytes chosen so BOTH offsets yield plausible epochs -
     * offset 1 reads 0x685E0060 = 1750990944 (2025), offset 0 would read 1577082881 (2019) - so this
     * genuinely pins the precedence, not just the happy path.
     */
    @Test
    fun setMirrorForm_takesPrecedenceOverBareRead() {
        val frame = responseFrame(payload = bytes(0x01, 0x60, 0x00, 0x5E, 0x68))
        assertEquals(1_750_990_944L, whoop4ArmedAlarmEpoch(frame))
    }

    /** A result-style single byte (e.g. an UNSUPPORTED echo) must not decode - raw-hex fallback. */
    @Test
    fun shortGarbagePayload_decodesNull() {
        assertNull(whoop4ArmedAlarmEpoch(responseFrame(payload = bytes(0x03))))
    }

    /** An implausible epoch (5 = 1970) is a disarmed/garbage answer, not an armed alarm. */
    @Test
    fun implausibleEpoch_decodesNull() {
        val frame = responseFrame(payload = bytes(0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
        assertNull(whoop4ArmedAlarmEpoch(frame))
    }

    /** An empty payload (header-only response) decodes null and yields no hex either. */
    @Test
    fun emptyPayload_decodesNullAndNoHex() {
        val frame = responseFrame(payload = ByteArray(0))
        assertNull(whoop4ArmedAlarmEpoch(frame))
        assertNull(whoop4AlarmReadbackPayloadHex(frame))
    }

    /** A truncated frame (shorter than its declared length) must decode null, never read out of bounds. */
    @Test
    fun truncatedFrame_decodesNull() {
        val full = responseFrame(payload = bytes(0x01, 0x30, 0xD5, 0x35, 0x6A, 0x00, 0x00, 0x00, 0x00))
        assertNull(whoop4ArmedAlarmEpoch(full.copyOfRange(0, full.size - 10)))
    }

    /** The raw-hex fallback renders the payload bytes space-separated lowercase, payload only. */
    @Test
    fun payloadHexFallback_rendersPayloadBytes() {
        val frame = responseFrame(payload = bytes(0x03, 0xAB))
        assertEquals("03 ab", whoop4AlarmReadbackPayloadHex(frame))
    }

    /** Pins the plausibility window bounds (2017..2100, inclusive) so a tweak can't silently widen it. */
    @Test
    fun plausibilityBounds() {
        assertTrue(isPlausibleAlarmEpoch(1_500_000_000L))
        assertFalse(isPlausibleAlarmEpoch(1_499_999_999L))
        assertTrue(isPlausibleAlarmEpoch(4_102_444_800L))
        assertFalse(isPlausibleAlarmEpoch(4_102_444_801L))
    }
}
