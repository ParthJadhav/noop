import Foundation

// MARK: - Decoded stream rows (the durable, compact local record)
// Phase E and WhoopStore depend on these EXACT shapes. ts is wall-clock unix seconds
// EXCEPT inside extractStreams' inputs; the structs themselves always carry wall-clock ts.

public struct HRSample: Equatable, Codable {
    public let ts: Int          // wall-clock unix seconds
    public let bpm: Int
    public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
}

public struct RRInterval: Equatable, Codable {
    public let ts: Int          // wall-clock unix seconds
    public let rrMs: Int
    public init(ts: Int, rrMs: Int) { self.ts = ts; self.rrMs = rrMs }
}

public struct WhoopEvent: Equatable, Codable {
    public let ts: Int          // real unix seconds (event RTC; never offset)
    public let kind: String
    public let payload: [String: ParsedValue]
    public init(ts: Int, kind: String, payload: [String: ParsedValue]) {
        self.ts = ts; self.kind = kind; self.payload = payload
    }
}

public struct BatterySample: Equatable, Codable {
    public let ts: Int          // unix seconds — event RTC for BATTERY_LEVEL events, else wallClockRef
    public let soc: Double?
    public let mv: Int?
    public let charging: Bool?  // only the BATTERY_LEVEL event reports this; nil otherwise
    public init(ts: Int, soc: Double?, mv: Int?, charging: Bool? = nil) {
        self.ts = ts; self.soc = soc; self.mv = mv; self.charging = charging
    }
}

// MARK: - type-47 HISTORICAL_DATA biometric rows. JSON keys MUST match
// biometric_streams_golden.json exactly (see extract_historical_streams).

public struct SpO2Sample: Equatable, Codable {
    public let ts: Int
    public let red: Int
    public let ir: Int
    public let unit: String     // "raw_adc"
    public init(ts: Int, red: Int, ir: Int, unit: String = "raw_adc") {
        self.ts = ts; self.red = red; self.ir = ir; self.unit = unit
    }
}

public struct SkinTempSample: Equatable, Codable {
    public let ts: Int
    public let raw: Int
    public let unit: String     // "raw_adc"
    public init(ts: Int, raw: Int, unit: String = "raw_adc") {
        self.ts = ts; self.raw = raw; self.unit = unit
    }
}

/// Convert a raw `skin_temp_raw` register value to °C, DEVICE-FAMILY-AWARE (#938).
///
/// The two families bank skin temp on DIFFERENT scales, and applying one family's scale to the other
/// is a real decode bug: the historical `skin_temp_raw` field is a RAW ADC on the WHOOP 4.0 (v24
/// `@72`, "degC computed server-side" per the schema) but a CENTIDEGREE register on the 5/MG (v18
/// `@73`). A single family-blind `raw/100` sent every 4.0 night ~8 °C low, below the 28 °C worn gate,
/// so skin temp and the illness signal vanished (issue #938, reporter dpguglielmi's 4.0 capture).
///
/// - `.whoop5`: `raw / 100`. PROVEN on real 5/MG captures — `Whoop5HistoricalTests` reads worn 3057 =
///   30.6 °C and off-wrist 2247 = 22.5 °C, physically right on both ends. Unchanged.
///
/// - `.whoop4`: a single-anchor affine map. The 4.0 firmware (41.17.6.0) banks byte-72 at 1 Hz
///   ON-WRIST ONLY, so there is ONE solid anchor and NO clean off-wrist room anchor from the strap.
///   The reporter's doff/don capture gives a steady worn resting value of raw ~826 (worn steady
///   ~830–865; a no-contact floor ~510–520 at removal, then banking stops). Under `/100` that worn
///   value reads ~8.3 °C — impossible for a wrist streaming a resting HR (~52 bpm). We anchor the
///   worn value at a defensible nocturnal wrist skin temperature (33.0 °C ↔ raw 826) and carry a
///   PROVISIONAL slope until a second calibration point exists. Because the downstream use is a
///   deviation from the user's OWN nightly baseline (`skinTempDevC`), the offset is what must be right
///   to clear the absolute 28–42 °C worn gate + 20–42 °C baseline clamp; a slope error only rescales
///   the deviation and stays directionally correct. All 4.0 values APPROXIMATE.
///
///   TODO(#938): replace the provisional slope with the exact two-point anchor once a second worn
///   point at a markedly different ambient (the reporter offered a colder + a warmer room) pins the
///   ADC→°C transfer — including whether it is linear at all. Until then this is a defensible
///   worn-range mapping, NOT a claimed-accurate absolute thermometer.
public func skinTempCelsius(raw: Int, family: DeviceFamily) -> Double {
    switch family {
    case .whoop5:
        return Double(raw) / 100.0
    case .whoop4:
        // Anchor: worn resting raw 826 → 33.0 °C. Provisional slope 0.05 °C per raw unit (a ~35-unit
        // worn-steady spread ≈ ~1.75 °C of nocturnal variation, within the plausible band). See TODO above.
        return Whoop4SkinTemp.anchorCelsius
            + (Double(raw) - Whoop4SkinTemp.anchorRaw) * Whoop4SkinTemp.provisionalSlopeCPerRaw
    }
}

/// WHOOP 4.0 (v24) skin-temp mapping constants (#938). Named so the single provisional slope + anchor
/// live in ONE place and the two-point-calibration TODO has an obvious home. Kept in lockstep with the
/// Android `Whoop4SkinTemp`.
public enum Whoop4SkinTemp {
    /// Worn resting raw register value the anchor pins (reporter's steady worn baseline, ~826).
    public static let anchorRaw: Double = 826.0
    /// Physiological nocturnal wrist skin temperature the anchor raw maps to (°C).
    public static let anchorCelsius: Double = 33.0
    /// PROVISIONAL °C-per-raw-unit slope. TODO(#938): replace with the two-point anchor slope.
    public static let provisionalSlopeCPerRaw: Double = 0.05
}

public struct RespSample: Equatable, Codable {
    public let ts: Int
    public let raw: Int
    public let unit: String     // "raw_adc"
    public init(ts: Int, raw: Int, unit: String = "raw_adc") {
        self.ts = ts; self.raw = raw; self.unit = unit
    }
}

public struct GravitySample: Equatable, Codable {
    public let ts: Int
    public let x: Double
    public let y: Double
    public let z: Double
    public let unit: String     // "g"
    public init(ts: Int, x: Double, y: Double, z: Double, unit: String = "g") {
        self.ts = ts; self.x = x; self.y = y; self.z = z; self.unit = unit
    }
}

/// WHOOP 5/MG cumulative u16 step / motion counter (step_motion_counter@57). APPROXIMATE — the @57
/// step semantics are unverified against the official WHOOP app (#78). Mirrors Android StepSample.
///
/// `activityClass` is the per-record activity-class enum decoded from @63 (community finding #316):
/// 0=still, 1=walk, 2=run; nil when the byte was 0xFF/invalid or absent. A lightweight, no-cloud
/// activity readout that rides alongside the counter. Optional + defaulted so existing call sites and
/// the persisted store (which carries only ts/counter today) are unchanged.
public struct StepSample: Equatable, Codable {
    public let ts: Int
    public let counter: Int
    public let activityClass: Int?
    public init(ts: Int, counter: Int, activityClass: Int? = nil) {
        self.ts = ts; self.counter = counter; self.activityClass = activityClass
    }
}

/// The strap's OWN per-record band sleep_state (task #175). The Interpreter reads the high nibble of the
/// v18 @81 flag byte (`(sb>>4)&3`) as 0 wake / 1 still / 2 asleep / 3 up. The BYTE and its offset are read
/// off real captured frames (Whoop5HistoricalTests) exactly like every other v18 field; ONLY the
/// meaning of the non-zero codes is community/structure inference (every real capture we hold reads 0, a
/// worn daytime wake). So this stream is carried VERBATIM (the strap's own byte, never fabricated) and is
/// surfaced/persisted as the strap's reported state, NOT trusted to override the derived hypnogram. It
/// feeds the existing, already-verified H7 morning-stillness re-onset CONFIRM guard (KEEP-biased, never
/// overrides) and a Deep Timeline display track. Mirrors Android `SleepStateRow`.
public struct SleepStateSample: Equatable, Codable {
    public let ts: Int
    public let state: Int       // 0 wake / 1 still / 2 asleep / 3 up (band's own high-nibble code)
    public init(ts: Int, state: Int) { self.ts = ts; self.state = state }
}

public struct Streams: Equatable, Codable {
    public var hr: [HRSample]
    public var rr: [RRInterval]
    public var spo2: [SpO2Sample]
    public var skinTemp: [SkinTempSample]
    public var resp: [RespSample]
    public var gravity: [GravitySample]
    public var steps: [StepSample]
    /// The strap's own per-record band sleep_state (#175), carried verbatim off @81's high nibble. Optional
    /// signal (only 5/MG v18 records emit it today; a WHOOP 4.0 leaves it empty), consumed by the H7
    /// re-onset CONFIRM guard and shown as a Deep Timeline track. Never overrides the derived stage.
    public var sleepState: [SleepStateSample]
    /// PPG-derived per-second HR from the WHOOP 5.0 v26 optical buffer (issue #156). Kept separate from
    /// `hr` (the measured stream) so consumers can COALESCE without conflating the two sources.
    public var ppgHr: [PpgHrSample]
    public var events: [WhoopEvent]
    public var battery: [BatterySample]
    /// #547 diagnostic: how many historical records `extractHistoricalStreams` DROPPED this chunk for an
    /// implausible own-timestamp (a bad-clock strap: far-past / bogus-2027 / future-dated). NOT persisted
    /// and NOT round-tripped through Codable (excluded from `CodingKeys`) — it is a transient observability
    /// count the Backfiller surfaces to the strap log. Defaults to 0 so it never affects golden fixtures.
    public var droppedImplausible: Int = 0
    public init(hr: [HRSample] = [], rr: [RRInterval] = [],
                spo2: [SpO2Sample] = [], skinTemp: [SkinTempSample] = [],
                resp: [RespSample] = [], gravity: [GravitySample] = [],
                steps: [StepSample] = [], sleepState: [SleepStateSample] = [],
                ppgHr: [PpgHrSample] = [],
                events: [WhoopEvent] = [], battery: [BatterySample] = []) {
        self.hr = hr; self.rr = rr
        self.spo2 = spo2; self.skinTemp = skinTemp; self.resp = resp; self.gravity = gravity
        self.steps = steps; self.sleepState = sleepState; self.ppgHr = ppgHr
        self.events = events; self.battery = battery
    }

    /// True when no decoded rows landed in any stream — used to flag a historical chunk whose frames
    /// all dropped (CRC fail / unmapped layout / out-of-range timestamp), the silent-data-loss
    /// diagnostic in `Backfiller.finishChunk` (#77).
    public var isEmpty: Bool {
        hr.isEmpty && rr.isEmpty && spo2.isEmpty && skinTemp.isEmpty && resp.isEmpty
            && gravity.isEmpty && steps.isEmpty && sleepState.isEmpty && ppgHr.isEmpty
            && events.isEmpty && battery.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case hr, rr, spo2, skinTemp = "skin_temp", resp, gravity, steps
        case sleepState = "sleep_state"
        case ppgHr = "ppg_hr"
        case events, battery
    }

    // Custom decode so older fixtures (streams_golden.json / historical_golden.json) that
    // lack the new biometric keys still decode — missing arrays default to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hr = try c.decodeIfPresent([HRSample].self, forKey: .hr) ?? []
        rr = try c.decodeIfPresent([RRInterval].self, forKey: .rr) ?? []
        spo2 = try c.decodeIfPresent([SpO2Sample].self, forKey: .spo2) ?? []
        skinTemp = try c.decodeIfPresent([SkinTempSample].self, forKey: .skinTemp) ?? []
        resp = try c.decodeIfPresent([RespSample].self, forKey: .resp) ?? []
        gravity = try c.decodeIfPresent([GravitySample].self, forKey: .gravity) ?? []
        steps = try c.decodeIfPresent([StepSample].self, forKey: .steps) ?? []
        sleepState = try c.decodeIfPresent([SleepStateSample].self, forKey: .sleepState) ?? []
        ppgHr = try c.decodeIfPresent([PpgHrSample].self, forKey: .ppgHr) ?? []
        events = try c.decodeIfPresent([WhoopEvent].self, forKey: .events) ?? []
        battery = try c.decodeIfPresent([BatterySample].self, forKey: .battery) ?? []
    }
}

extension Streams { public static let empty = Streams() }

/// Map a device-epoch timestamp to wall-clock unix seconds via a pure linear offset.
/// Assumes strap clock and wall clock tick at the same rate (no skew/drift). Port of _to_wall.
private func toWall(_ deviceTs: Int?, _ deviceClockRef: Int, _ wallClockRef: Int) -> Int? {
    guard let deviceTs = deviceTs else { return nil }
    return wallClockRef + (deviceTs - deviceClockRef)
}

/// Turn parsed frames into datastore rows. Port of interpreter.extract_streams.
///
/// HR/R-R are taken ONLY from REALTIME_DATA (type 40). REALTIME_RAW_DATA (type 43) also
/// carries an HR byte but streams alongside type-40 during raw collection, so routing both
/// would double-count HR for the same instants. CRC-failed and non-ok frames are skipped.
public func extractStreams(_ parsed: [ParsedFrame],
                           deviceClockRef: Int, wallClockRef: Int) -> Streams {
    var out = Streams()
    for r in parsed {
        if !r.ok || r.crcOK == false { continue }
        let p = r.parsed
        switch r.typeName {
        case "REALTIME_DATA":
            let ts = toWall(p["timestamp"]?.intValue, deviceClockRef, wallClockRef)
            if let ts = ts, let bpm = p["heart_rate"]?.intValue {
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            // Unlike Python, drop RR rows when timestamp is absent (a ts-less RR row is unstorable).
            if let ts = ts, let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
        case "EVENT":
            // EVENT timestamps are real RTC unix seconds — already wall-clock, NOT offset.
            guard let ts = p["event_timestamp"]?.intValue else { continue }
            let kind = p["event"]?.stringValue ?? ""
            // BATTERY_LEVEL events (every ~8 min) carry SoC/mV/charging + a real RTC ts →
            // the DENSE battery series (the post-hook decoded the fields).
            if kind.hasPrefix("BATTERY_LEVEL") { appendBattery(&out, ts: ts, p: p) }  // "BATTERY_LEVEL(3)"
            var payload = p
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "event_timestamp")
            out.events.append(WhoopEvent(ts: ts, kind: kind, payload: payload))
        case "COMMAND_RESPONSE":
            // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
            appendBattery(&out, ts: wallClockRef, p: p)
        default:
            continue
        }
    }
    return out
}

/// Append a BatterySample from a parsed frame's battery_pct/battery_mV/battery_charging
/// fields (no-op when neither soc nor mv is present). charging is a real Bool only when the
/// frame reported it (BATTERY_LEVEL events); command responses leave it nil.
func appendBattery(_ out: inout Streams, ts: Int, p: [String: ParsedValue]) {
    let soc = p["battery_pct"]?.doubleValue
    let mv = p["battery_mV"]?.intValue
    guard soc != nil || mv != nil else { return }
    let charging = p["battery_charging"]?.intValue.map { $0 != 0 }
    out.battery.append(BatterySample(ts: ts, soc: soc, mv: mv, charging: charging))
}
