import Foundation

// Decoders: pure per-tag byte->value decoders (OURA_PROTOCOL.md s6). Each returns nil on a
// malformed/short record (honest-data invariant): NEVER a guessed value. Body offsets in the spec are
// relative to the start of the RECORD (offset 6 = first body byte); the parsed OuraRecord already
// stripped the 6-byte header, so here `body[0]` == spec offset 6.
//
// FOOTGUN WATCH (per the brief + OURA_PROTOCOL.md s6 risks):
//   - 0x7B SpO2 is BIG-endian (the lone exception to the LE default).
//   - 0x6E reads IBIs in REVERSE byte order.
//   - 0x80 / 0x60 are bit-packed across byte boundaries.
//   - live-HR IBI uses a 12-bit LE-ish nibble at subBody[5..6]: ((b6 & 0x0F) << 8) | b5.
//
// Platform-pure value types. All facts cited tersely per OURA_PROTOCOL.md s6.

public enum OuraDecoders {

    // MARK: - Little-endian helpers (body offset == spec offset - 6)

    @inline(__always) static func u16le(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8)
    }
    @inline(__always) static func u16be(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 8) | Int(b[i + 1])
    }
    @inline(__always) static func i16le(_ b: [UInt8], _ i: Int) -> Int {
        Int(Int16(bitPattern: UInt16(b[i]) | (UInt16(b[i + 1]) << 8)))
    }
    @inline(__always) static func u24le(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16)
    }
    @inline(__always) static func u32le(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    // MARK: - Live-HR realtime push (0x2F sub-op 0x28; s5.6)

    /// Decode a live-HR push body (the bytes AFTER `2f 0f 28`). Per OURA_PROTOCOL.md s5.6 the wire
    /// frame is `2f 0f 28 02 XX 02 00 00 IBI_L IBI_H 00 00 00 00 YY ZZ 7f`. The spec lists the IBI at
    /// frame bytes 8-9; once the transport strips the 3-byte `2f 0f 28` prefix those indices shift down
    /// by 3, so within this subBody the IBI sits at subBody[5..6] as a 12-bit value:
    /// ((b6 & 0x0F) << 8) | b5; bpm = round(60000 / ibi). Returns nil on a short body or a
    /// zero/implausible IBI.
    ///
    /// `ringTimestamp` is supplied by the caller (the push is not a TLV record; the driver stamps it
    /// with the live ring time). Example subBody[5..6] = `01 04` -> ibi 1025 ms -> ~59 bpm.
    public static func decodeLiveHRPush(_ body: [UInt8], ringTimestamp: UInt32) -> OuraHR? {
        guard body.count >= 7 else { return nil }
        let ibi = ((Int(body[6]) & 0x0F) << 8) | Int(body[5])
        guard ibi > 0 else { return nil }
        let bpm = Int((60000.0 / Double(ibi)).rounded())
        guard bpm > 0 && bpm < 300 else { return nil }   // reject implausible derived BPM, never guess
        return OuraHR(ringTimestamp: ringTimestamp, bpm: bpm, ibiMs: ibi)
    }

    // MARK: - IBI + amplitude, bit-packed (0x60; s6.1)

    /// Decode the 0x60 ibi_and_amplitude_event: 6 IBI+amplitude pairs bit-packed across the body.
    /// IBI = 11-bit value (ms); amplitude = 7-bit mantissa (byte bits [7:1]) shifted left by the
    /// exponent; exponent = low nibble of the last body byte (shift = (n==7) ? 0 : n+1). Per
    /// OURA_PROTOCOL.md s6.1. Returns nil on a short body. A bit-reader walks the body MSB-first.
    public static func decodeIBIAmplitude(_ rec: OuraRecord) -> [OuraIBI]? {
        let b = rec.payload
        // Need at least the 14 packed bytes the spec describes (body bytes 6..19 inclusive = 14 bytes).
        guard b.count >= 14 else { return nil }
        let n = Int(b[b.count - 1] & 0x0F)
        let shift = (n == 7) ? 0 : (n + 1)
        var reader = BitReader(b)
        var out: [OuraIBI] = []
        for _ in 0..<6 {
            guard let raw11 = reader.read(11) else { break }
            guard let mant7 = reader.read(7) else { break }
            let ibi = raw11                                   // 11-bit value -> ms
            let amp = mant7 << shift                           // 7-bit mantissa << exponent
            guard ibi > 0 else { continue }                   // drop a zero IBI, never invent one
            out.append(OuraIBI(ringTimestamp: rec.ringTimestamp, ibiMs: ibi, amplitude: amp))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Green IBI quality, 2 bytes/sample (0x80; s6.4)

    /// Decode the 0x80 green_ibi_quality_event: per 16-bit LE sample, bits 0-10 = IBI ms,
    /// bits 11-13 = qual_a, bits 14-15 = qual_b. Accept a sample only if qual_a <= 1 && qual_b == 0.
    /// 7 samples per 14-byte record. Per OURA_PROTOCOL.md s6.4. Returns nil on a short/odd body.
    ///
    /// ROBUSTNESS (s6.4): the record holds at most 7 samples (14 bytes at 2 B/sample). We cap the read
    /// at 7 samples; any sample bytes beyond the 7th are a misframe and are ignored rather than decoded.
    public static func decodeGreenIBIQuality(_ rec: OuraRecord) -> [OuraIBI]? {
        let b = rec.payload
        guard b.count >= 2, b.count % 2 == 0 else { return nil }
        let maxSamples = 7                            // s6.4: 7 samples per 14-byte record
        var out: [OuraIBI] = []
        var i = 0
        var sampleCount = 0
        while i + 1 < b.count && sampleCount < maxSamples {
            let sample = u16le(b, i)
            let ibi = sample & 0x07FF                 // bits 0-10
            let qualA = (sample >> 11) & 0x07         // bits 11-13
            let qualB = (sample >> 14) & 0x03         // bits 14-15
            if qualA <= 1 && qualB == 0 && ibi > 0 {
                out.append(OuraIBI(ringTimestamp: rec.ringTimestamp, ibiMs: ibi))
            }
            i += 2
            sampleCount += 1
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - SpO2 IBI + amplitude, REVERSE byte order (0x6E; s6.3)

    /// Decode the 0x6E spo2_ibi_and_amplitude_event: byte6 bits [7:6]=flag+shift, [3:0]=mode;
    /// 5 IBIs as 8-bit counts x8 read bytes 11->7 (REVERSE). Per OURA_PROTOCOL.md s6.3. Returns nil on
    /// a short body. (The reverse read is the footgun: we walk index 11 down to 7.)
    ///
    /// SCOPE NOTE (honest, not accidental): the 0x6E record also carries a 7-amplitude PPG channel
    /// (s6.3: "7 amplitudes: first byte<<3, rest byte<<shift"). NOOP v1 deliberately decodes the R-R
    /// (IBI) channel ONLY and drops the amplitude channel, exactly as the 0x47 motion decoder is held
    /// out of v1 scope. This partial decode is an explicit scope choice, not a missed field.
    public static func decodeSpO2IBI(_ rec: OuraRecord) -> [OuraIBI]? {
        let b = rec.payload
        // body[0] is spec offset 6; the 5 IBI bytes are spec offsets 7..11 => body[1..5], read reversed.
        guard b.count >= 6 else { return nil }
        var out: [OuraIBI] = []
        var idx = 5
        while idx >= 1 {
            let ibi = Int(b[idx]) * 8                  // 8-bit count x8 -> ms
            if ibi > 0 {
                out.append(OuraIBI(ringTimestamp: rec.ringTimestamp, ibiMs: ibi))
            }
            idx -= 1
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - HRV / RMSSD (0x5D; s6.9)

    /// Decode the 0x5D hrv_event: samples each carrying a time_ms field + two int8 fields (b1, b2).
    /// Per OURA_PROTOCOL.md s6.9 the per-sample stride is time(2 LE) + b1(1) + b2(1) = 4 bytes.
    /// Returns nil on a short body. NOOP consumes this as the ring's OWN RMSSD-derived HRV tag.
    public static func decodeHRV(_ rec: OuraRecord) -> [OuraHRV]? {
        let b = rec.payload
        guard b.count >= 4 else { return nil }
        var out: [OuraHRV] = []
        var i = 0
        while i + 4 <= b.count {
            let timeMs = u16le(b, i)
            let v1 = Int(Int8(bitPattern: b[i + 2]))
            let v2 = Int(Int8(bitPattern: b[i + 3]))
            out.append(OuraHRV(ringTimestamp: rec.ringTimestamp, timeMs: timeMs, b1: v1, b2: v2))
            i += 4
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - SpO2 per-sample (0x6F; s6.5)

    /// Decode the 0x6F spo2_event: byte6 bits [7:4]=SpO2 base/status field, [3:0]=status flag; then one
    /// uint8 SpO2 value per second from byte7 onward (optional 0xFF terminator). Per OURA_PROTOCOL.md
    /// s6.5. Returns nil on a short body.
    public static func decodeSpO2PerSample(_ rec: OuraRecord) -> [OuraSpO2]? {
        let b = rec.payload
        guard b.count >= 2 else { return nil }
        // byte6 high nibble [7:4] is a base/status field, NOT an offset to add to each sample. Real Gen 3
        // captures (#968, pipiche38) show samples[] are DIRECT SpO2 percentages (~95-96), so adding the
        // scaled base produced impossible ~223% readings. The samples themselves are the percentage.
        var out: [OuraSpO2] = []
        var i = 1
        while i < b.count {
            let raw = Int(b[i])
            if raw == 0xFF { break }                  // terminator
            out.append(OuraSpO2(ringTimestamp: rec.ringTimestamp, value: raw))
            i += 1
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - SpO2 stable, BIG-endian (0x7B; s6.6)

    /// Decode the 0x7B spo2_stable_event: a SINGLE uint16 BIG-endian at bytes 6-7. This is the lone
    /// exception to the LE default. Per OURA_PROTOCOL.md s6.6. Returns nil on a short body.
    public static func decodeSpO2Stable(_ rec: OuraRecord) -> OuraSpO2? {
        let b = rec.payload
        guard b.count >= 2 else { return nil }
        let value = u16be(b, 0)                       // BIG-endian footgun
        return OuraSpO2(ringTimestamp: rec.ringTimestamp, value: value)
    }

    // MARK: - SpO2 DC, sign-magnitude deltas (0x77; s6.7)

    /// Decode the 0x77 spo2_dc_event: byte6 bit[7]=HDR low bit, bit[6]=hasBase, bits[5:4]=scale shift.
    /// If hasBase: bytes 7-9 = 24-bit LE base. Remaining bytes are sign-magnitude int8 deltas:
    /// v=(int8)raw; mag=|v|<<scale; out = v<0 ? -mag : mag, accumulated. Per OURA_PROTOCOL.md s6.7.
    public static func decodeSpO2DC(_ rec: OuraRecord) -> [OuraSpO2]? {
        let b = rec.payload
        guard b.count >= 1 else { return nil }
        let header = Int(b[0])
        let hasBase = (header & 0x40) != 0
        let scale = (header >> 4) & 0x03
        var i = 1
        var acc = 0
        if hasBase {
            guard b.count >= 4 else { return nil }
            acc = u24le(b, 1)
            i = 4
        }
        var out: [OuraSpO2] = []
        if hasBase {
            out.append(OuraSpO2(ringTimestamp: rec.ringTimestamp, value: acc, unit: "dc_raw"))
        }
        while i < b.count {
            let v = Int(Int8(bitPattern: b[i]))
            let mag = abs(v) << scale
            acc += (v < 0) ? -mag : mag
            out.append(OuraSpO2(ringTimestamp: rec.ringTimestamp, value: acc, unit: "dc_raw"))
            i += 1
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Temperature (0x46 / 0x69 / 0x75; s6.8)

    /// Decode the 0x46 temp_event: up to 7 samples, each int16 LE / 100 = C. Even body length.
    /// Per OURA_PROTOCOL.md s6.8. Returns nil on a short/odd body.
    ///
    /// ROBUSTNESS (s6.8): the record holds at most 7 samples. We cap the read at 7; sample bytes beyond
    /// the 7th are a misframe (a longer record is not a real temp_event) and are ignored.
    public static func decodeTemp(_ rec: OuraRecord) -> [OuraTemp]? {
        let b = rec.payload
        guard b.count >= 2, b.count % 2 == 0 else { return nil }
        let maxSamples = 7                            // s6.8: up to 7 samples per temp_event
        var out: [OuraTemp] = []
        var i = 0
        while i + 1 < b.count && out.count < maxSamples {
            let c = Double(i16le(b, i)) / 100.0
            out.append(OuraTemp(ringTimestamp: rec.ringTimestamp, celsius: c))
            i += 2
        }
        return out.isEmpty ? nil : out
    }

    /// Decode the 0x69 temp_period: a single int16 LE / 100 = C. Per OURA_PROTOCOL.md s6.8.
    public static func decodeTempPeriod(_ rec: OuraRecord) -> OuraTemp? {
        let b = rec.payload
        guard b.count >= 2 else { return nil }
        return OuraTemp(ringTimestamp: rec.ringTimestamp, celsius: Double(i16le(b, 0)) / 100.0)
    }

    /// Decode the 0x75 sleep_temp_event: uint16 LE / 100 = C, 30-second spacing. Per OURA_PROTOCOL.md
    /// s6.8. Returns nil on a short/odd body.
    public static func decodeSleepTemp(_ rec: OuraRecord) -> [OuraTemp]? {
        let b = rec.payload
        guard b.count >= 2, b.count % 2 == 0 else { return nil }
        var out: [OuraTemp] = []
        var i = 0
        while i + 1 < b.count {
            let c = Double(u16le(b, i)) / 100.0       // unsigned for sleep temp
            out.append(OuraTemp(ringTimestamp: rec.ringTimestamp, celsius: c))
            i += 2
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Battery (0x0D outer response; s6.10)

    /// Decode the 0x0D battery response BODY (the 8 bytes after `0d <len>`). percent at body[0];
    /// voltage estimate as uint16 LE at body[4..6] (fallback only). charging_progress at body[1],
    /// recommended_flag at body[2]. Per OURA_PROTOCOL.md s6.10. Returns nil on a short body.
    ///
    /// CONFLICT (s6.10): open_oura-r3 reads percent at body[0], open_ring reads voltage at [4]. NOOP
    /// rule: percent from body[0]; voltage from [4..6] is a fixture-validated fallback estimate only.
    public static func decodeBattery(_ body: [UInt8]) -> OuraBattery? {
        guard body.count >= 3 else { return nil }
        let percent = Int(body[0])
        guard percent <= 100 else { return nil }       // a >100 "percent" is a misread, not a guess
        let chargingProgress = Int(body[1])
        let voltage: Int? = body.count >= 6 ? u16le(body, 4) : nil
        // charging_progress > 0 indicates an active charge cycle (per s6.10 field name).
        return OuraBattery(percent: percent, voltageMv: voltage, charging: chargingProgress > 0)
    }

    // MARK: - Time sync (0x42; s6.11)

    /// Decode the 0x42 time-sync ind: bytes 6-13 = int64 LE epoch ms; byte14 = int8 tz offset in
    /// 30-min units (x1800 = seconds). Per OURA_PROTOCOL.md s6.11. Returns nil on a short body.
    public static func decodeTimeSync(_ rec: OuraRecord) -> OuraTimeSync? {
        let b = rec.payload
        // body[0..8] = epoch ms (8 bytes), body[8] = tz offset.
        guard b.count >= 9 else { return nil }
        var epoch: UInt64 = 0
        for k in 0..<8 { epoch |= UInt64(b[k]) << (8 * k) }
        let tz = Int(Int8(bitPattern: b[8])) * 1800
        return OuraTimeSync(ringTimestamp: rec.ringTimestamp,
                            epochMs: Int64(bitPattern: epoch), tzOffsetSeconds: tz)
    }

    // MARK: - RTC beacon (0x85; s6.15)

    /// Decode the 0x85 rtc_beacon_ind: unix_s u32 LE, reserved 4 B, trailer u16 LE in {0x01F6,0x01F8}.
    /// Per OURA_PROTOCOL.md s6.15. Returns nil on a short body.
    public static func decodeRtcBeacon(_ rec: OuraRecord) -> OuraRtcBeacon? {
        let b = rec.payload
        guard b.count >= 4 else { return nil }
        return OuraRtcBeacon(ringTimestamp: rec.ringTimestamp, unixSeconds: u32le(b, 0))
    }

    // MARK: - State / wear (0x45 / 0x53; s6.15)

    /// Decode the 0x45 state_change_ind / 0x53 wear_event: byte6 = STATE_* enum; optional trailing
    /// UTF-8 string when payload > 5. Per OURA_PROTOCOL.md s6.15. Returns nil on an empty body.
    public static func decodeState(_ rec: OuraRecord) -> OuraState? {
        let b = rec.payload
        guard let code = b.first else { return nil }
        var text: String? = nil
        if b.count > 5 {
            text = String(bytes: b[1...], encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0000}"))
        }
        return OuraState(ringTimestamp: rec.ringTimestamp, stateCode: Int(code), text: text)
    }

    // MARK: - Debug text (0x43; s6.15)

    /// Decode the 0x43 debug_event: ASCII state strings. Per OURA_PROTOCOL.md s6.15. Returns nil when
    /// the body is empty or not decodable text.
    public static func decodeDebugText(_ rec: OuraRecord) -> String? {
        guard !rec.payload.isEmpty else { return nil }
        return String(bytes: rec.payload, encoding: .utf8)
    }

    // MARK: - Sleep phase, 2-bit codes (0x4E / 0x5A; s6.12)

    /// Decode the 0x4E/0x5A sleep_phase_details: byte6 = header; phase codes are 2-bit, 4 per byte
    /// (bits [7:6][5:4][3:2][1:0]); codes 0=awake,1=light,2=deep,3=REM. Per OURA_PROTOCOL.md s6.12.
    /// Returns nil on a short body. The header byte is skipped; phase bytes follow.
    public static func decodeSleepPhase(_ rec: OuraRecord) -> [OuraSleepPhase]? {
        let b = rec.payload
        // body[0] is the header (spec offset 6); phase codes begin at body[1].
        guard b.count >= 2 else { return nil }
        var out: [OuraSleepPhase] = []
        var index = 0
        for k in 1..<b.count {
            let byte = b[k]
            // MSB-first within the byte: [7:6] is the first code.
            for shift in stride(from: 6, through: 0, by: -2) {
                let code = Int((byte >> UInt8(shift)) & 0x03)
                if let stage = OuraSleepStage(rawValue: code) {
                    out.append(OuraSleepPhase(ringTimestamp: rec.ringTimestamp, index: index, stage: stage))
                    index += 1
                }
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Motion period, 2-bit MOTION_STATE codes (0x6B; s6.13)

    /// Decode the 0x6B motion_period: 12-bit period header, byte6 bits[5:4]=leading-symbol count, then
    /// 2-bit MOTION_STATE codes, 4 per byte (MSB-first). 0=NO_MOTION,1=RESTLESS,2=TOSSING,3=ACTIVE.
    /// Per OURA_PROTOCOL.md s6.13. Returns nil on a short body. The first two bytes carry the period
    /// header; codes follow from byte index 2.
    public static func decodeMotionPeriod(_ rec: OuraRecord) -> [OuraMotion]? {
        let b = rec.payload
        guard b.count >= 3 else { return nil }
        var out: [OuraMotion] = []
        var index = 0
        for k in 2..<b.count {
            let byte = b[k]
            for shift in stride(from: 6, through: 0, by: -2) {
                let code = Int((byte >> UInt8(shift)) & 0x03)
                if let state = OuraMotionState(rawValue: code) {
                    out.append(OuraMotion(ringTimestamp: rec.ringTimestamp, index: index, state: state))
                    index += 1
                }
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Activity info (0x50; s6.13) - Tier B, third-party formula

    /// Decode the 0x50 activity_info record: byte0 = a `state` code (activity-category; meaning
    /// unconfirmed), every following byte = one MET sample. Formula (OURA_PROTOCOL.md s6.13, [oura-rs],
    /// clean-room fact citation): `met = byte * 0.1` for byte < 0x80, else `met = 12.8 + (byte - 128) * 0.2`
    /// (a two-slope encoding: 0.1-MET resolution up to 12.7, coarser 0.2 steps above). THIRD-PARTY and NOT
    /// ground-truth-validated against the Oura app, so this stays Tier B end to end: OuraDriver gates it
    /// behind `allowTierB`, and OuraStreamMapping never folds it into a durable stream. Values are
    /// normalised to 2 decimal places so a decoded MET compares exactly against its fixture (0.1 is not
    /// exactly representable in binary floating point). Returns nil on an empty body - a record with no
    /// state byte decodes to nothing, never a guess.
    public static func decodeActivityInfo(_ rec: OuraRecord) -> OuraActivityInfo? {
        let b = rec.payload
        guard let state = b.first else { return nil }
        let met: [Double] = b.dropFirst().map { byte in
            let raw = byte < 0x80 ? Double(byte) * 0.1 : 12.8 + (Double(byte) - 128.0) * 0.2
            return (raw * 100).rounded() / 100
        }
        return OuraActivityInfo(ringTimestamp: rec.ringTimestamp, state: Int(state), met: met)
    }
}

// MARK: - Bit reader (MSB-first), used by the bit-packed decoders (0x60)

/// A minimal MSB-first bit reader over a byte array. Used for the bit-packed IBI+amplitude layout
/// (OURA_PROTOCOL.md s6.1) where 11-bit IBI and 7-bit amplitude fields straddle byte boundaries.
/// Returns nil when fewer than the requested bits remain (so the decoder stops cleanly, never guesses).
struct BitReader {
    private let bytes: [UInt8]
    private var bitPos = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int? {
        guard bitPos + count <= bytes.count * 8 else { return nil }
        var value = 0
        for _ in 0..<count {
            let byteIndex = bitPos >> 3
            let bitIndex = 7 - (bitPos & 7)               // MSB-first
            let bit = (Int(bytes[byteIndex]) >> bitIndex) & 1
            value = (value << 1) | bit
            bitPos += 1
        }
        return value
    }
}
