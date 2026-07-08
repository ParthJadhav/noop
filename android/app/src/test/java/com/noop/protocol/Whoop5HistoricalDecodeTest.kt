package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/**
 * WHOOP 5.0/MG type-47 "v18" historical decode (Android), against the SAME real captured frames the
 * macOS `Whoop5HistoricalTests` uses — so both platforms are verified to decode byte-for-byte identical
 * data. Offsets are WHOOP5-absolute (record @8), NOT the WHOOP4 V24 layout. Each per-second biometric
 * field is gated to a physical range; this test pins the real decoded values.
 */
class Whoop5HistoricalDecodeTest {

    private fun bytes(s: String): ByteArray =
        s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // Real worn WHOOP 5 v18 frame: hr=102, rr=[602,613] ms, |gravity|≈1, skin temp 30.57 °C.
    private val wornV18 =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    // Real off-wrist v18 frame (hr=0): same thermistor reads ambient (~22.5 °C), not skin.
    private val offWristV18 =
        "aa01740001003fb12f12803a3d84018889266a3d0a00000000000000000000000000000000000000000064c33b52b47d3fe1ba1dbda470ecbd000064000000000000000000e500e200c708000c010c020c0000000000000000000000000000000000000000000000010000008080000000000000000000009ffafe6c"

    @Test
    fun decodesWhoop5V18CoreAndBiometrics() {
        val p = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)
        assertNotNull(p)
        p!!
        assertEquals(18, p["hist_version"])
        assertEquals(1780916150, p["unix"])
        assertEquals(102, p["heart_rate"])
        assertEquals(2, p["rr_count"])
        assertEquals(listOf(602, 613), p["rr_intervals"])

        val gx = p["gravity_x"] as Double
        val gy = p["gravity_y"] as Double
        val gz = p["gravity_z"] as Double
        assertEquals(1.0, sqrt(gx * gx + gy * gy + gz * gz), 0.05)

        // Per-second biometric fields (verified vs the real frame).
        assertEquals(3057, p["skin_temp_raw"]) // 30.57 °C
        // @57 decodes as the FULL little-endian u16 at [57:59], not byte @57 alone (the over-count fix).
        assertEquals(50, p["step_motion_counter"])
        assertEquals(0, p["motion_wear_quality"])
        // @63 also reads as the activity-class enum (#316): this worn-still frame's byte is 0 => still.
        assertEquals(0, p["activity_class"])
        assertTrue((p["dynamic_acceleration"] as Double) in 0.0..8.0)
    }

    /** Mutate one absolute frame byte and re-stamp the CRC32 (over frame[8..len-4]) so it passes the gate. */
    private fun mutateAndReCrc(index: Int, value: Int): ByteArray {
        val f = bytes(wornV18); f[index] = value.toByte()
        val end = f.size - 4
        val crc = Crc.crc32(f.copyOfRange(8, end))
        f[end] = (crc and 0xFF).toByte(); f[end + 1] = ((crc shr 8) and 0xFF).toByte()
        f[end + 2] = ((crc shr 16) and 0xFF).toByte(); f[end + 3] = ((crc shr 24) and 0xFF).toByte()
        return f
    }

    @Test
    fun decodesV18ActivityClassEnum() {
        // @63 is a small validated activity-class enum: 0=still, 1=walk, 2=run, 0xFF=invalid (#316).
        // The four known codes map through; 0xFF and any other value store nothing (null).
        assertEquals(0, decodeHistorical(mutateAndReCrc(63, 0), DeviceFamily.WHOOP5)!!["activity_class"]) // still
        assertEquals(1, decodeHistorical(mutateAndReCrc(63, 1), DeviceFamily.WHOOP5)!!["activity_class"]) // walk
        assertEquals(2, decodeHistorical(mutateAndReCrc(63, 2), DeviceFamily.WHOOP5)!!["activity_class"]) // run
        assertNull(decodeHistorical(mutateAndReCrc(63, 0xFF), DeviceFamily.WHOOP5)!!["activity_class"])   // invalid
        assertNull(decodeHistorical(mutateAndReCrc(63, 7), DeviceFamily.WHOOP5)!!["activity_class"])      // unknown
    }

    @Test
    fun stepCounterIsFullU16NotLowByte() {
        // The over-count bug (#132/#276): @57 must decode as the FULL little-endian u16 at [57:59], so the
        // high byte @58 is honoured. The fixture's low byte @57 is 0x32 (50); setting high byte @58 = 0x01
        // must read 0x0132 (= 306), NOT the low byte 50 alone.
        assertEquals(0x0132, decodeHistorical(mutateAndReCrc(58, 0x01), DeviceFamily.WHOOP5)!!["step_motion_counter"])
    }

    @Test
    fun decodesV18ObservedFields() {
        // Fields read off the same real worn frame, justified by observed behaviour (parity with the
        // Swift Whoop5HistoricalTests.testHistoricalV18ObservedFields).
        val p = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!
        assertEquals(25443699, p["record_index"])               // @11 per-record counter
        assertEquals(25997, p["hr_fixed_8_8"])                  // @36 value/256 ≈ HR (101.55 ≈ 102)
        assertEquals(101, (p["hr_fixed_8_8"] as Int) / 256)
        assertEquals(170, p["step_cadence"])                    // @59 cadence-like byte (raw)
        assertEquals(1792, p["status_word"])                    // @75 not a deep-sleep marker
        assertEquals(0, p["sleep_state"])                       // @81 worn daytime frame = wake
        assertEquals(25444, p["rr_packed"])
        assertEquals(0, p["cardiac_flags"])
        assertEquals(255, p["cardiac_status"])
        assertEquals(-5.2307, p["unknown_f32_113"] as Double, 0.001)  // @113 float, purpose unknown

        // Newly-mapped adjacent fields (read off the same real worn frame).
        assertEquals(247, p["temp_aux_1_raw"])  // @69 signed i16, °C = raw/10 ≈ 24.7
        assertEquals(265, p["temp_aux_2_raw"])  // @71 signed i16, ≈ 26.5
        assertEquals(3057, p["skin_temp_raw"])  // @73 raw u16, °C = raw/100 ≈ 30.57 (physiological)
        assertEquals(3073, p["status_word_1"])  // @77 raw u16
        assertEquals(3074, p["status_word_2"])  // @79 raw u16
        assertEquals(0, p["wake_quality"])      // @81 bits 2-3
        assertEquals(0, p["onwrist"])           // @81 bits 0-1 (worn daytime, low nibble 0)
        assertEquals(0, p["aux_byte_82"])       // @82 raw byte
    }

    @Test
    fun decodesV18AuxFieldsAcrossDevices() {
        // The aux thermal pair, status words, on-wrist bit, and aux byte read consistently off the
        // other real fixtures. The second-device HR57 frame has the @81 on-wrist bit set (low nibble 1).
        val ack = decodeHistorical(bytes(androidAckCaptureV18), DeviceFamily.WHOOP5)!!
        assertEquals(294, ack["temp_aux_1_raw"])
        assertEquals(310, ack["temp_aux_2_raw"])
        assertEquals(3073, ack["status_word_1"])
        assertEquals(3074, ack["status_word_2"])
        assertEquals(3238, ack["skin_temp_raw"]) // 32.38 °C with the /100 scale

        val dev57 = decodeHistorical(bytes(secondDeviceHR57), DeviceFamily.WHOOP5)!!
        assertEquals(1, dev57["onwrist"])         // @81 low nibble = 1 on this frame
        assertEquals(0, dev57["wake_quality"])
        assertEquals(0, dev57["sleep_state"])
        assertEquals(2962, dev57["skin_temp_raw"]) // 29.62 °C
    }

    @Test
    fun band81NibblesSplitIndependently() {
        // @81 packs sleep_state (bits 4-5), wake_quality (bits 2-3) and onwrist (bits 0-1). Override the
        // byte on the real fixture and re-stamp the CRC32 (over frame[8..len-4], per Framing) so it passes
        // the gate, then check each sub-field is sliced independently.
        data class Exp(val raw: Int, val sleep: Int, val wakeQ: Int, val onwrist: Int)
        for (e in listOf(
            Exp(0x00, 0, 0, 0),
            Exp(0x39, 3, 2, 1),   // 0b00_11_10_01
            Exp(0x16, 1, 1, 2),   // 0b00_01_01_10
            Exp(0x2B, 2, 2, 3),   // 0b00_10_10_11
        )) {
            val f = bytes(wornV18); f[81] = e.raw.toByte()
            val end = f.size - 4
            val crc = Crc.crc32(f.copyOfRange(8, end))
            f[end] = (crc and 0xFF).toByte(); f[end + 1] = ((crc shr 8) and 0xFF).toByte()
            f[end + 2] = ((crc shr 16) and 0xFF).toByte(); f[end + 3] = ((crc shr 24) and 0xFF).toByte()
            val p = decodeHistorical(f, DeviceFamily.WHOOP5)!!
            assertEquals(e.sleep, p["sleep_state"])
            assertEquals(e.wakeQ, p["wake_quality"])
            assertEquals(e.onwrist, p["onwrist"])
        }
    }

    @Test
    fun sleepStateReadsHighNibbleOnly() {
        // @81 high nibble = band sleep state; low nibble = sub-flags. Override that byte on the real
        // fixture and re-stamp the CRC32 (over frame[8..len-4], per Framing) so it passes the gate.
        for ((raw, expected) in listOf(0x00 to 0, 0x10 to 1, 0x20 to 2, 0x30 to 3, 0x25 to 2)) {
            val f = bytes(wornV18); f[81] = raw.toByte()
            val end = f.size - 4
            val crc = Crc.crc32(f.copyOfRange(8, end))
            f[end] = (crc and 0xFF).toByte(); f[end + 1] = ((crc shr 8) and 0xFF).toByte()
            f[end + 2] = ((crc shr 16) and 0xFF).toByte(); f[end + 3] = ((crc shr 24) and 0xFF).toByte()
            assertEquals(expected, decodeHistorical(f, DeviceFamily.WHOOP5)!!["sleep_state"])
        }
    }

    // #175: the decoded band sleep_state must now survive extractHistoricalStreams as a SleepStateRow (it
    // was decoded but DROPPED before). On the REAL worn daytime fixture the band reads 0 (wake) — the only
    // value we have ever captured — carried VERBATIM (0 is a real wake reading, NOT "absent").
    @Test
    fun sleepStateReachesStreamOnRealFixture() {
        val st = extractHistoricalStreams(listOf(bytes(wornV18)), 1780916150, 1780916150, DeviceFamily.WHOOP5)
        assertEquals(listOf(com.noop.data.SleepStateRow(1780916150L, 0)), st.sleepState)
    }

    // The non-zero codes come only from an in-memory byte override (we hold NO real sleeping-night capture),
    // so this proves the PLUMBING carries whatever the band reports. The CRC is re-stamped so the extractor's
    // CRC gate passes; it does NOT assert the code meanings against real data.
    @Test
    fun sleepStateStreamCarriesEachNibble() {
        for ((raw, expected) in listOf(0x10 to 1, 0x20 to 2, 0x30 to 3)) {
            val frame = mutateAndReCrc(81, raw)
            val st = extractHistoricalStreams(listOf(frame), 1780916150, 1780916150, DeviceFamily.WHOOP5)
            assertEquals(listOf(com.noop.data.SleepStateRow(1780916150L, expected)), st.sleepState)
        }
    }

    @Test
    fun skinTempTracksWristContact() {
        val worn = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!
        val off = decodeHistorical(bytes(offWristV18), DeviceFamily.WHOOP5)!!
        assertEquals(3057, worn["skin_temp_raw"]) // ~30.6 °C on the wrist
        assertEquals(2247, off["skin_temp_raw"]) // ~22.5 °C off the wrist (ambient), still within guard
    }

    @Test
    fun whoop4FamilyDoesNotMisreadAWhoop5Frame() {
        // Decoding a WHOOP5 frame as WHOOP4 must yield null (different envelope; type@4 != 47 / CRC differs)
        assertNull(decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP4))
    }

    // Real Android WHOOP 5.0 v18 frame from an ACK-enabled hardware offload (a clock-synced strap
    // releasing genuine body frames) — independent ground truth for the same offsets. (#78 fork)
    private val androidAckCaptureV18 =
        "aa01740001003fb12f1280aaae6f01bea0286ae11a004200000000000000000000b0000084414b38dc80b96c3c717d243dd7638f3ee182773ff6007e00000000000000000026013601a60c5004010c020c00000000000000000000000000000000000000000000010100a27c2521000000bff73ec00000002ce4150a"

    @Test
    fun decodesAndroidAckCaptureV18() {
        val p = decodeHistorical(bytes(androidAckCaptureV18), DeviceFamily.WHOOP5)
        assertNotNull(p)
        p!!
        assertEquals(18, p["hist_version"])
        assertEquals(1781047486, p["unix"])
        assertEquals(66, p["heart_rate"])
        assertEquals(3238, p["skin_temp_raw"]) // 32.38 °C on the wrist
        val gx = p["gravity_x"] as Double
        val gy = p["gravity_y"] as Double
        val gz = p["gravity_z"] as Double
        assertEquals(1.0, sqrt(gx * gx + gy * gy + gz * gz), 0.05)
    }

    // A SECOND device (Galaxy S24 Ultra capture, 2026-06-11). Each HR was cross-checked against the
    // SAME device's own live REALTIME_DATA at the identical unix second (57 & 63 bpm matched exactly,
    // 53/53 over the overlap) — ground truth, not self-referential. Pins that v18 GENERALISES.
    private val secondDeviceHR57 =
        "aa01740001003fb12f128093c47c006dbc296a00600039000000000000000000006137020b610000e1e04c063d8fce36bf7b08233f8fea993e38a50000000000000000000019012101920b5002010c020c0100000000000000000000000000000000000000000005010085808080000000a5538ec000000016d0680d"
    private val secondDeviceHR63 =
        "aa01740001003fb12f128034d67c000ece296a0a77003f01fc0300000000000000203a0302e30000ff00f8093c1f8534bcc3a5473f4819243f85a6000000000000000000001b012601e80b5003010c020c00000000000000000000000000000000000000000000050100ced7241c0000006ead8cc00000008775b70c"

    @Test
    fun decodesV18FromASecondDevice() {
        for ((hex, expectHR, expectUnix) in listOf(
            Triple(secondDeviceHR57, 57, 1781120109),
            Triple(secondDeviceHR63, 63, 1781124622),
        )) {
            val p = decodeHistorical(bytes(hex), DeviceFamily.WHOOP5)
            assertNotNull(p); p!!
            assertEquals(18, p["hist_version"])
            assertEquals(expectUnix, p["unix"])
            assertEquals(expectHR, p["heart_rate"]) // == the device's own live HR at this second
            val gx = p["gravity_x"] as Double
            val gy = p["gravity_y"] as Double
            val gz = p["gravity_z"] as Double
            assertEquals(1.0, sqrt(gx * gx + gy * gy + gz * gz), 0.2)
        }
    }
}
