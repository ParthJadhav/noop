package com.noop.oura

// Decoders: pure per-tag byte->value decoders (OURA_PROTOCOL.md s6). Kotlin twin of Decoders.swift.
// Each returns null on a malformed/short record (honest-data invariant): NEVER a guessed value. Body
// offsets in the spec are relative to the start of the RECORD (offset 6 = first body byte); the parsed
// OuraRecord already stripped the 6-byte header, so here `body[0]` == spec offset 6.
//
// FOOTGUN WATCH (per the brief + OURA_PROTOCOL.md s6 risks):
//   - 0x7B SpO2 is BIG-endian (the lone exception to the LE default).
//   - 0x6E reads IBIs in REVERSE byte order.
//   - 0x80 / 0x60 are bit-packed across byte boundaries.
//   - live-HR IBI uses a 12-bit LE-ish nibble at subBody[5..6]: ((b6 & 0x0F) << 8) | b5.
//
// DIVERGENCE FROM SWIFT: payload bytes are unsigned-byte Ints (0..255) in an IntArray (see Framing.kt
// note), so a signed int16/int8 read goes through an explicit sign-extension helper rather than
// Swift's Int16(bitPattern:)/Int8(bitPattern:). The numeric results are identical.
//
// Platform-pure value types. All facts cited tersely per OURA_PROTOCOL.md s6.

object OuraDecoders {

    // MARK: - Little-endian helpers (body offset == spec offset - 6)

    private fun u16le(b: IntArray, i: Int): Int = b[i] or (b[i + 1] shl 8)

    private fun u16be(b: IntArray, i: Int): Int = (b[i] shl 8) or b[i + 1]

    /** Signed 16-bit LE: sign-extend the assembled u16. Mirrors Swift Int16(bitPattern:). */
    private fun i16le(b: IntArray, i: Int): Int = (b[i] or (b[i + 1] shl 8)).toShort().toInt()

    private fun u24le(b: IntArray, i: Int): Int = b[i] or (b[i + 1] shl 8) or (b[i + 2] shl 16)

    private fun u32le(b: IntArray, i: Int): Long =
        (b[i].toLong() and 0xFFL) or ((b[i + 1].toLong() and 0xFFL) shl 8) or
            ((b[i + 2].toLong() and 0xFFL) shl 16) or ((b[i + 3].toLong() and 0xFFL) shl 24)

    /** Signed 8-bit: sign-extend an unsigned byte. Mirrors Swift Int8(bitPattern:). */
    private fun i8(v: Int): Int = v.toByte().toInt()

    // MARK: - Live-HR realtime push (0x2F sub-op 0x28; s5.6)

    /**
     * Decode a live-HR push body (the bytes AFTER `2f 0f 28`). Per OURA_PROTOCOL.md s5.6 the wire
     * frame is `2f 0f 28 02 XX 02 00 00 IBI_L IBI_H 00 00 00 00 YY ZZ 7f`. The spec lists the IBI at
     * frame bytes 8-9; once the transport strips the 3-byte `2f 0f 28` prefix those indices shift down
     * by 3, so within this subBody the IBI sits at subBody[5..6] as a 12-bit value:
     * ((b6 & 0x0F) << 8) | b5; bpm = round(60000 / ibi). Returns null on a short body or a
     * zero/implausible IBI.
     *
     * `ringTimestamp` is supplied by the caller (the push is not a TLV record; the driver stamps it
     * with the live ring time). Example subBody[5..6] = `01 04` -> ibi 1025 ms -> ~59 bpm.
     */
    fun decodeLiveHRPush(body: IntArray, ringTimestamp: Long): OuraHR? {
        if (body.size < 7) return null
        val ibi = ((body[6] and 0x0F) shl 8) or body[5]
        if (ibi <= 0) return null
        val bpm = Math.round(60000.0 / ibi.toDouble()).toInt()
        if (bpm <= 0 || bpm >= 300) return null   // reject implausible derived BPM, never guess
        return OuraHR(ringTimestamp = ringTimestamp, bpm = bpm, ibiMs = ibi)
    }

    // MARK: - IBI + amplitude, bit-packed (0x60; s6.1)

    /**
     * Decode the 0x60 ibi_and_amplitude_event: 6 IBI+amplitude pairs bit-packed across the body.
     * IBI = 11-bit value (ms); amplitude = 7-bit mantissa (byte bits [7:1]) shifted left by the
     * exponent; exponent = low nibble of the last body byte (shift = (n==7) ? 0 : n+1). Per
     * OURA_PROTOCOL.md s6.1. Returns null on a short body. A bit-reader walks the body MSB-first.
     */
    fun decodeIBIAmplitude(rec: OuraRecord): List<OuraIBI>? {
        val b = rec.payload
        // Need at least the 14 packed bytes the spec describes (body bytes 6..19 inclusive = 14 bytes).
        if (b.size < 14) return null
        val n = b[b.size - 1] and 0x0F
        val shift = if (n == 7) 0 else (n + 1)
        val reader = BitReader(b)
        val out = ArrayList<OuraIBI>()
        for (k in 0 until 6) {
            val raw11 = reader.read(11) ?: break
            val mant7 = reader.read(7) ?: break
            val ibi = raw11                               // 11-bit value -> ms
            val amp = mant7 shl shift                      // 7-bit mantissa << exponent
            if (ibi <= 0) continue                         // drop a zero IBI, never invent one
            out.add(OuraIBI(ringTimestamp = rec.ringTimestamp, ibiMs = ibi, amplitude = amp))
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - Green IBI quality, 2 bytes/sample (0x80; s6.4)

    /**
     * Decode the 0x80 green_ibi_quality_event: per 16-bit LE sample, bits 0-10 = IBI ms,
     * bits 11-13 = qual_a, bits 14-15 = qual_b. Accept a sample only if qual_a <= 1 && qual_b == 0.
     * 7 samples per 14-byte record. Per OURA_PROTOCOL.md s6.4. Returns null on a short/odd body.
     *
     * ROBUSTNESS (s6.4): the record holds at most 7 samples (14 bytes at 2 B/sample). We cap the read
     * at 7 samples; any sample bytes beyond the 7th are a misframe and are ignored rather than decoded.
     */
    fun decodeGreenIBIQuality(rec: OuraRecord): List<OuraIBI>? {
        val b = rec.payload
        if (b.size < 2 || b.size % 2 != 0) return null
        val maxSamples = 7                              // s6.4: 7 samples per 14-byte record
        val out = ArrayList<OuraIBI>()
        var i = 0
        var sampleCount = 0
        while (i + 1 < b.size && sampleCount < maxSamples) {
            val sample = u16le(b, i)
            val ibi = sample and 0x07FF                 // bits 0-10
            val qualA = (sample shr 11) and 0x07        // bits 11-13
            val qualB = (sample shr 14) and 0x03        // bits 14-15
            if (qualA <= 1 && qualB == 0 && ibi > 0) {
                out.add(OuraIBI(ringTimestamp = rec.ringTimestamp, ibiMs = ibi))
            }
            i += 2
            sampleCount += 1
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - SpO2 IBI + amplitude, REVERSE byte order (0x6E; s6.3)

    /**
     * Decode the 0x6E spo2_ibi_and_amplitude_event: byte6 bits [7:6]=flag+shift, [3:0]=mode;
     * 5 IBIs as 8-bit counts x8 read bytes 11->7 (REVERSE). Per OURA_PROTOCOL.md s6.3. Returns null on
     * a short body. (The reverse read is the footgun: we walk index 11 down to 7.)
     *
     * SCOPE NOTE (honest, not accidental): the 0x6E record also carries a 7-amplitude PPG channel
     * (s6.3: "7 amplitudes: first byte<<3, rest byte<<shift"). NOOP v1 deliberately decodes the R-R
     * (IBI) channel ONLY and drops the amplitude channel, exactly as the 0x47 motion decoder is held
     * out of v1 scope. This partial decode is an explicit scope choice, not a missed field.
     */
    fun decodeSpO2IBI(rec: OuraRecord): List<OuraIBI>? {
        val b = rec.payload
        // body[0] is spec offset 6; the 5 IBI bytes are spec offsets 7..11 => body[1..5], read reversed.
        if (b.size < 6) return null
        val out = ArrayList<OuraIBI>()
        var idx = 5
        while (idx >= 1) {
            val ibi = b[idx] * 8                          // 8-bit count x8 -> ms
            if (ibi > 0) {
                out.add(OuraIBI(ringTimestamp = rec.ringTimestamp, ibiMs = ibi))
            }
            idx -= 1
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - HRV / RMSSD (0x5D; s6.9)

    /**
     * Decode the 0x5D hrv_event: samples each carrying a time_ms field + two int8 fields (b1, b2).
     * Per OURA_PROTOCOL.md s6.9 the per-sample stride is time(2 LE) + b1(1) + b2(1) = 4 bytes.
     * Returns null on a short body. NOOP consumes this as the ring's OWN RMSSD-derived HRV tag.
     */
    fun decodeHRV(rec: OuraRecord): List<OuraHRV>? {
        val b = rec.payload
        if (b.size < 4) return null
        val out = ArrayList<OuraHRV>()
        var i = 0
        while (i + 4 <= b.size) {
            val timeMs = u16le(b, i)
            val v1 = i8(b[i + 2])
            val v2 = i8(b[i + 3])
            out.add(OuraHRV(ringTimestamp = rec.ringTimestamp, timeMs = timeMs, b1 = v1, b2 = v2))
            i += 4
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - SpO2 per-sample (0x6F; s6.5)

    /**
     * Decode the 0x6F spo2_event: byte6 bits [7:4]=SpO2 base (<<7), [3:0]=status flag; then one
     * uint8 SpO2 value per second from byte7 onward (optional 0xFF terminator). Per OURA_PROTOCOL.md
     * s6.5. Returns null on a short body.
     */
    fun decodeSpO2PerSample(rec: OuraRecord): List<OuraSpO2>? {
        val b = rec.payload
        if (b.size < 2) return null
        // byte6 high nibble [7:4] is a base/status field, NOT an offset to add to each sample. Real Gen 3
        // captures (#968, pipiche38) show samples[] are DIRECT SpO2 percentages (~95-96), so adding the
        // scaled base produced impossible ~223% readings. The samples themselves are the percentage.
        val out = ArrayList<OuraSpO2>()
        var i = 1
        while (i < b.size) {
            val raw = b[i]
            if (raw == 0xFF) break                       // terminator
            out.add(OuraSpO2(ringTimestamp = rec.ringTimestamp, value = raw))
            i += 1
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - SpO2 stable, BIG-endian (0x7B; s6.6)

    /**
     * Decode the 0x7B spo2_stable_event: a SINGLE uint16 BIG-endian at bytes 6-7. This is the lone
     * exception to the LE default. Per OURA_PROTOCOL.md s6.6. Returns null on a short body.
     */
    fun decodeSpO2Stable(rec: OuraRecord): OuraSpO2? {
        val b = rec.payload
        if (b.size < 2) return null
        val value = u16be(b, 0)                          // BIG-endian footgun
        return OuraSpO2(ringTimestamp = rec.ringTimestamp, value = value)
    }

    // MARK: - SpO2 DC, sign-magnitude deltas (0x77; s6.7)

    /**
     * Decode the 0x77 spo2_dc_event: byte6 bit[7]=HDR low bit, bit[6]=hasBase, bits[5:4]=scale shift.
     * If hasBase: bytes 7-9 = 24-bit LE base. Remaining bytes are sign-magnitude int8 deltas:
     * v=(int8)raw; mag=|v|<<scale; out = v<0 ? -mag : mag, accumulated. Per OURA_PROTOCOL.md s6.7.
     */
    fun decodeSpO2DC(rec: OuraRecord): List<OuraSpO2>? {
        val b = rec.payload
        if (b.isEmpty()) return null
        val header = b[0]
        val hasBase = (header and 0x40) != 0
        val scale = (header shr 4) and 0x03
        var i = 1
        var acc = 0
        if (hasBase) {
            if (b.size < 4) return null
            acc = u24le(b, 1)
            i = 4
        }
        val out = ArrayList<OuraSpO2>()
        if (hasBase) {
            out.add(OuraSpO2(ringTimestamp = rec.ringTimestamp, value = acc, unit = "dc_raw"))
        }
        while (i < b.size) {
            val v = i8(b[i])
            val mag = Math.abs(v) shl scale
            acc += if (v < 0) -mag else mag
            out.add(OuraSpO2(ringTimestamp = rec.ringTimestamp, value = acc, unit = "dc_raw"))
            i += 1
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - Temperature (0x46 / 0x69 / 0x75; s6.8)

    /**
     * Decode the 0x46 temp_event: up to 7 samples, each int16 LE / 100 = C. Even body length.
     * Per OURA_PROTOCOL.md s6.8. Returns null on a short/odd body.
     *
     * ROBUSTNESS (s6.8): the record holds at most 7 samples. We cap the read at 7; sample bytes beyond
     * the 7th are a misframe (a longer record is not a real temp_event) and are ignored.
     */
    fun decodeTemp(rec: OuraRecord): List<OuraTemp>? {
        val b = rec.payload
        if (b.size < 2 || b.size % 2 != 0) return null
        val maxSamples = 7                              // s6.8: up to 7 samples per temp_event
        val out = ArrayList<OuraTemp>()
        var i = 0
        while (i + 1 < b.size && out.size < maxSamples) {
            val c = i16le(b, i).toDouble() / 100.0
            out.add(OuraTemp(ringTimestamp = rec.ringTimestamp, celsius = c))
            i += 2
        }
        return if (out.isEmpty()) null else out
    }

    /** Decode the 0x69 temp_period: a single int16 LE / 100 = C. Per OURA_PROTOCOL.md s6.8. */
    fun decodeTempPeriod(rec: OuraRecord): OuraTemp? {
        val b = rec.payload
        if (b.size < 2) return null
        return OuraTemp(ringTimestamp = rec.ringTimestamp, celsius = i16le(b, 0).toDouble() / 100.0)
    }

    /**
     * Decode the 0x75 sleep_temp_event: uint16 LE / 100 = C, 30-second spacing. Per OURA_PROTOCOL.md
     * s6.8. Returns null on a short/odd body.
     */
    fun decodeSleepTemp(rec: OuraRecord): List<OuraTemp>? {
        val b = rec.payload
        if (b.size < 2 || b.size % 2 != 0) return null
        val out = ArrayList<OuraTemp>()
        var i = 0
        while (i + 1 < b.size) {
            val c = u16le(b, i).toDouble() / 100.0        // unsigned for sleep temp
            out.add(OuraTemp(ringTimestamp = rec.ringTimestamp, celsius = c))
            i += 2
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - Battery (0x0D outer response; s6.10)

    /**
     * Decode the 0x0D battery response BODY (the 8 bytes after `0d <len>`). percent at body[0];
     * voltage estimate as uint16 LE at body[4..6] (fallback only). charging_progress at body[1],
     * recommended_flag at body[2]. Per OURA_PROTOCOL.md s6.10. Returns null on a short body.
     *
     * CONFLICT (s6.10): open_oura-r3 reads percent at body[0], open_ring reads voltage at [4]. NOOP
     * rule: percent from body[0]; voltage from [4..6] is a fixture-validated fallback estimate only.
     */
    fun decodeBattery(body: IntArray): OuraBattery? {
        if (body.size < 3) return null
        val percent = body[0]
        if (percent > 100) return null                   // a >100 "percent" is a misread, not a guess
        val chargingProgress = body[1]
        val voltage: Int? = if (body.size >= 6) u16le(body, 4) else null
        // charging_progress > 0 indicates an active charge cycle (per s6.10 field name).
        return OuraBattery(percent = percent, voltageMv = voltage, charging = chargingProgress > 0)
    }

    // MARK: - Time sync (0x42; s6.11)

    /**
     * Decode the 0x42 time-sync ind: bytes 6-13 = int64 LE epoch ms; byte14 = int8 tz offset in
     * 30-min units (x1800 = seconds). Per OURA_PROTOCOL.md s6.11. Returns null on a short body.
     */
    fun decodeTimeSync(rec: OuraRecord): OuraTimeSync? {
        val b = rec.payload
        // body[0..8] = epoch ms (8 bytes), body[8] = tz offset.
        if (b.size < 9) return null
        var epoch = 0L
        for (k in 0 until 8) epoch = epoch or ((b[k].toLong() and 0xFFL) shl (8 * k))
        val tz = i8(b[8]) * 1800
        return OuraTimeSync(ringTimestamp = rec.ringTimestamp, epochMs = epoch, tzOffsetSeconds = tz)
    }

    // MARK: - RTC beacon (0x85; s6.15)

    /**
     * Decode the 0x85 rtc_beacon_ind: unix_s u32 LE, reserved 4 B, trailer u16 LE in {0x01F6,0x01F8}.
     * Per OURA_PROTOCOL.md s6.15. Returns null on a short body.
     */
    fun decodeRtcBeacon(rec: OuraRecord): OuraRtcBeacon? {
        val b = rec.payload
        if (b.size < 4) return null
        return OuraRtcBeacon(ringTimestamp = rec.ringTimestamp, unixSeconds = u32le(b, 0))
    }

    // MARK: - State / wear (0x45 / 0x53; s6.15)

    /**
     * Decode the 0x45 state_change_ind / 0x53 wear_event: byte6 = STATE_* enum; optional trailing
     * UTF-8 string when payload > 5. Per OURA_PROTOCOL.md s6.15. Returns null on an empty body.
     */
    fun decodeState(rec: OuraRecord): OuraState? {
        val b = rec.payload
        if (b.isEmpty()) return null
        val code = b[0]
        var text: String? = null
        if (b.size > 5) {
            val tailBytes = ByteArray(b.size - 1) { b[it + 1].toByte() }
            // Swift trims the NUL character set; match that exactly (trim only U+0000, not whitespace).
            text = String(tailBytes, Charsets.UTF_8).trim('\u0000')
        }
        return OuraState(ringTimestamp = rec.ringTimestamp, stateCode = code, text = text)
    }

    // MARK: - Debug text (0x43; s6.15)

    /**
     * Decode the 0x43 debug_event: ASCII state strings. Per OURA_PROTOCOL.md s6.15. Returns null when
     * the body is empty.
     */
    fun decodeDebugText(rec: OuraRecord): String? {
        if (rec.payload.isEmpty()) return null
        val raw = ByteArray(rec.payload.size) { rec.payload[it].toByte() }
        return String(raw, Charsets.UTF_8)
    }

    // MARK: - Sleep phase, 2-bit codes (0x4E / 0x5A; s6.12)

    /**
     * Decode the 0x4E/0x5A sleep_phase_details: byte6 = header; phase codes are 2-bit, 4 per byte
     * (bits [7:6][5:4][3:2][1:0]); codes 0=awake,1=light,2=deep,3=REM. Per OURA_PROTOCOL.md s6.12.
     * Returns null on a short body. The header byte is skipped; phase bytes follow.
     */
    fun decodeSleepPhase(rec: OuraRecord): List<OuraSleepPhase>? {
        val b = rec.payload
        // body[0] is the header (spec offset 6); phase codes begin at body[1].
        if (b.size < 2) return null
        val out = ArrayList<OuraSleepPhase>()
        var index = 0
        for (k in 1 until b.size) {
            val byte = b[k]
            // MSB-first within the byte: [7:6] is the first code.
            var shift = 6
            while (shift >= 0) {
                val code = (byte shr shift) and 0x03
                val stage = OuraSleepStage.fromRaw(code)
                if (stage != null) {
                    out.add(OuraSleepPhase(ringTimestamp = rec.ringTimestamp, index = index, stage = stage))
                    index += 1
                }
                shift -= 2
            }
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - Motion period, 2-bit MOTION_STATE codes (0x6B; s6.13)

    /**
     * Decode the 0x6B motion_period: 12-bit period header, byte6 bits[5:4]=leading-symbol count, then
     * 2-bit MOTION_STATE codes, 4 per byte (MSB-first). 0=NO_MOTION,1=RESTLESS,2=TOSSING,3=ACTIVE.
     * Per OURA_PROTOCOL.md s6.13. Returns null on a short body. The first two bytes carry the period
     * header; codes follow from byte index 2.
     */
    fun decodeMotionPeriod(rec: OuraRecord): List<OuraMotion>? {
        val b = rec.payload
        if (b.size < 3) return null
        val out = ArrayList<OuraMotion>()
        var index = 0
        for (k in 2 until b.size) {
            val byte = b[k]
            var shift = 6
            while (shift >= 0) {
                val code = (byte shr shift) and 0x03
                val state = OuraMotionState.fromRaw(code)
                if (state != null) {
                    out.add(OuraMotion(ringTimestamp = rec.ringTimestamp, index = index, state = state))
                    index += 1
                }
                shift -= 2
            }
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - Activity info (0x50; s6.13) - Tier B, third-party formula

    /**
     * Decode the 0x50 activity_info record: byte0 = a `state` code (activity-category; meaning
     * unconfirmed), every following byte = one MET sample. Formula (OURA_PROTOCOL.md s6.13, [oura-rs],
     * clean-room fact citation): `met = byte * 0.1` for byte < 0x80, else `met = 12.8 + (byte - 128) * 0.2`
     * (a two-slope encoding: 0.1-MET resolution up to 12.7, coarser 0.2 steps above). THIRD-PARTY and NOT
     * ground-truth-validated against the Oura app, so this stays Tier B end to end: OuraDriver gates it
     * behind `allowTierB`, and OuraStreamMapping never folds it into a durable stream. Values are
     * normalised to 2 decimal places so a decoded MET compares exactly against its fixture (0.1 is not
     * exactly representable in binary floating point; same normalisation as the Swift twin, so both
     * platforms decode identical doubles). Returns null on an empty body - a record with no state byte
     * decodes to nothing, never a guess.
     */
    fun decodeActivityInfo(rec: OuraRecord): OuraActivityInfo? {
        val b = rec.payload
        if (b.isEmpty()) return null
        val met = ArrayList<Double>(b.size - 1)
        for (k in 1 until b.size) {
            val raw = if (b[k] < 0x80) b[k] * 0.1 else 12.8 + (b[k] - 128) * 0.2
            met.add(Math.round(raw * 100.0) / 100.0)
        }
        return OuraActivityInfo(ringTimestamp = rec.ringTimestamp, state = b[0], met = met)
    }
}

// MARK: - Bit reader (MSB-first), used by the bit-packed decoders (0x60)

/**
 * A minimal MSB-first bit reader over an unsigned-byte IntArray. Used for the bit-packed IBI+amplitude
 * layout (OURA_PROTOCOL.md s6.1) where 11-bit IBI and 7-bit amplitude fields straddle byte boundaries.
 * Returns null when fewer than the requested bits remain (so the decoder stops cleanly, never guesses).
 * Kotlin twin of the Swift BitReader.
 */
internal class BitReader(private val bytes: IntArray) {
    private var bitPos = 0

    fun read(count: Int): Int? {
        if (bitPos + count > bytes.size * 8) return null
        var value = 0
        repeat(count) {
            val byteIndex = bitPos shr 3
            val bitIndex = 7 - (bitPos and 7)             // MSB-first
            val bit = (bytes[byteIndex] shr bitIndex) and 1
            value = (value shl 1) or bit
            bitPos += 1
        }
        return value
    }
}
