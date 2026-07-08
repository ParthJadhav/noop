import Foundation

// MARK: - Standard fitness-sensor (RSC / CSC / CPS) pure decoders
//
// Spec-deterministic field parsing for the three standard Bluetooth SIG fitness-sensor profiles a
// connected accessory exposes ALONGSIDE the Heart Rate profile (0x180D) — a running footpod, a bike
// speed/cadence sensor, or a crank/hub power meter:
//
//   • Running Speed and Cadence (RSC)   service 0x1814   measurement 0x2A53
//   • Cycling Speed and Cadence (CSC)    service 0x1816   measurement 0x2A5B
//   • Cycling Power (CPS)                service 0x1818   measurement 0x2A63
//
// Each measurement begins with a flags field whose bits gate which fields follow in a FIXED spec order.
// We decode the fields NOOP surfaces in a live workout (speed, cadence, power, and the cumulative
// revolution counters CSC/CPS report) and IGNORE the rest by advancing the cursor by their spec width,
// so an unrecognised optional field never desynchronises the ones after it.
//
// HONEST DATA: RSC carries instantaneous speed + cadence directly. CSC and CPS instead report CUMULATIVE
// revolution counts plus the time of the last event; an *instantaneous* speed / cadence / pedal cadence
// is DERIVED from the difference between two successive packets — there is no single-packet truth for it.
// `FitnessRateComputer` does that derivation as a pure value type, and a first packet (no prior to diff
// against) yields nil rather than a fabricated number. CPS instantaneous power IS a direct field.
//
// SECURITY / ROBUSTNESS: the byte buffer is UNTRUSTED BLE input. Every read is bounds-checked against the
// buffer length; a truncated/malformed packet yields the fields decoded so far (never a crash, never a
// read past the end) — the same bounds discipline as `FTMSDecode` and `StandardHeartRate.parse`.
//
// Pure value types, no CoreBluetooth — unit tested headlessly (`swift test`) against byte fixtures built
// from the spec, exactly like `FTMSDecode`. The app-target standard-sensor glue calls in here.
//
// Reference: Bluetooth SIG "Running Speed and Cadence Service" 1.0, "Cycling Speed and Cadence Service"
// 1.0, "Cycling Power Service" 1.1, and the GATT Specification Supplement field tables. NOOP's own clean
// re-implementation of the public spec (no GPL/AGPL source consulted — facts only).

/// Which standard fitness-sensor measurement produced a reading.
public enum FitnessSensorKind: String, Sendable, Equatable, Codable {
    case runningSpeedCadence    // RSC, 0x2A53
    case cyclingSpeedCadence    // CSC, 0x2A5B
    case cyclingPower           // CPS, 0x2A63

    /// The 16-bit measurement-characteristic UUID short form this kind streams.
    public var characteristicUUID16: String {
        switch self {
        case .runningSpeedCadence: return "2A53"
        case .cyclingSpeedCadence: return "2A5B"
        case .cyclingPower:        return "2A63"
        }
    }

    /// A human label for a live readout. Honest, no claim beyond the sensor kind.
    public var displayName: String {
        switch self {
        case .runningSpeedCadence: return "Running Sensor"
        case .cyclingSpeedCadence: return "Cycling Sensor"
        case .cyclingPower:        return "Power Meter"
        }
    }
}

/// A single decoded fitness-sensor measurement. Every field is OPTIONAL — a sensor advertises only a
/// subset, and a truncated packet decodes only what fit.
///
/// For CSC/CPS the cumulative `wheelRevolutions` / `crankRevolutions` and their event-time stamps are the
/// RAW spec fields; `FitnessRateComputer` turns successive readings into instantaneous speed/cadence. RSC
/// reports `speedMps` and `runningCadenceSpm` directly. CPS reports `instantaneousPowerWatts` directly.
public struct FitnessSensorReading: Equatable, Sendable {
    public let kind: FitnessSensorKind

    // RSC direct fields ---------------------------------------------------------------------------
    /// Instantaneous speed in metres/second (RSC). nil for CSC/CPS (derived instead).
    public var speedMps: Double?
    /// Instantaneous running cadence in steps/minute (RSC). nil for CSC/CPS.
    public var runningCadenceSpm: Int?
    /// True when the RSC sensor reports the user is running (vs walking); nil when not an RSC packet.
    public var isRunning: Bool?
    /// Total distance this session in metres, if the RSC sensor reports it (optional field).
    public var totalDistanceM: Double?

    // CPS direct field ----------------------------------------------------------------------------
    /// Instantaneous power in watts (CPS, sint16). nil for RSC/CSC.
    public var instantaneousPowerWatts: Int?

    // CSC / CPS cumulative fields (raw — feed the rate computer for instantaneous values) ----------
    /// Cumulative wheel revolutions (CSC wheel data, or CPS optional wheel data) — u32.
    public var cumulativeWheelRevolutions: UInt32?
    /// Last wheel-event time, wrapping at 65536 (u16). UNIT IS SOURCE-DEPENDENT: 1/1024 s from CSC
    /// (0x2A5B) but 1/2048 s from CPS (0x2A63) — Cycling Power Service 1.1, Wheel Revolution Data.
    /// `FitnessRateComputer` branches on `kind`; the field name keeps the CSC unit for Kotlin↔Swift
    /// parity with the shipped schema rather than churning every call-site (PR #1007).
    public var lastWheelEventTime1024: Int?
    /// Cumulative crank revolutions (CSC crank data, or CPS crank data) — u16.
    public var cumulativeCrankRevolutions: Int?
    /// Last crank-event time, unit 1/1024 s, wrapping at 65536 (u16).
    public var lastCrankEventTime1024: Int?

    public init(kind: FitnessSensorKind,
                speedMps: Double? = nil, runningCadenceSpm: Int? = nil, isRunning: Bool? = nil,
                totalDistanceM: Double? = nil, instantaneousPowerWatts: Int? = nil,
                cumulativeWheelRevolutions: UInt32? = nil, lastWheelEventTime1024: Int? = nil,
                cumulativeCrankRevolutions: Int? = nil, lastCrankEventTime1024: Int? = nil) {
        self.kind = kind
        self.speedMps = speedMps
        self.runningCadenceSpm = runningCadenceSpm
        self.isRunning = isRunning
        self.totalDistanceM = totalDistanceM
        self.instantaneousPowerWatts = instantaneousPowerWatts
        self.cumulativeWheelRevolutions = cumulativeWheelRevolutions
        self.lastWheelEventTime1024 = lastWheelEventTime1024
        self.cumulativeCrankRevolutions = cumulativeCrankRevolutions
        self.lastCrankEventTime1024 = lastCrankEventTime1024
    }

    /// Speed in km/h, if this reading carries a direct instantaneous speed (RSC). nil otherwise.
    public var speedKmh: Double? { speedMps.map { $0 * 3.6 } }
}

/// Pure decoders for the three standard fitness-sensor measurement characteristics. Stateless.
public enum FitnessSensorDecode {

    // MARK: - Little-endian readers (bounds-checked over UNTRUSTED input) — same shape as FTMSDecode.Reader

    private struct Reader {
        let bytes: [UInt8]
        var idx: Int = 0

        mutating func u8() -> Int? {
            guard idx < bytes.count else { return nil }
            defer { idx += 1 }
            return Int(bytes[idx])
        }
        mutating func u16() -> Int? {
            guard idx + 1 < bytes.count else { return nil }
            defer { idx += 2 }
            return Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
        }
        /// Signed 16-bit (two's complement) — CPS instantaneous power is sint16.
        mutating func s16() -> Int? {
            guard let raw = u16() else { return nil }
            return raw >= 0x8000 ? raw - 0x10000 : raw
        }
        mutating func u24() -> Int? {
            guard idx + 2 < bytes.count else { return nil }
            defer { idx += 3 }
            return Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8) | (Int(bytes[idx + 2]) << 16)
        }
        mutating func u32() -> UInt32? {
            guard idx + 3 < bytes.count else { return nil }
            defer { idx += 4 }
            return UInt32(bytes[idx]) | (UInt32(bytes[idx + 1]) << 8)
                | (UInt32(bytes[idx + 2]) << 16) | (UInt32(bytes[idx + 3]) << 24)
        }
        mutating func skip(_ n: Int) { idx = min(bytes.count, idx + n) }
    }

    // MARK: - Running Speed and Cadence (0x2A53)
    //
    // Flags (u8) then, IN ORDER:
    //   —     Instantaneous Speed   u16, unit 1/256 m/s   (ALWAYS present)
    //   —     Instantaneous Cadence u8,  steps/min        (ALWAYS present)
    //   bit0  Instantaneous Stride Length present → u16, unit 1/100 m
    //   bit1  Total Distance present        → u32, unit 1/10 m
    //   bit2  Walking(0) or Running(1)      → no field; a flag bit only
    public static func runningSpeedCadence(_ data: [UInt8]) -> FitnessSensorReading? {
        var r = Reader(bytes: data)
        guard let flags = r.u8() else { return nil }
        var out = FitnessSensorReading(kind: .runningSpeedCadence)

        if let raw = r.u16() { out.speedMps = Double(raw) / 256.0 }   // 1/256 m/s
        if let cad = r.u8() { out.runningCadenceSpm = cad }           // steps/min
        if flags & 0x01 != 0 { _ = r.u16() }                         // Instantaneous Stride Length (skip)
        if flags & 0x02 != 0, let d = r.u32() { out.totalDistanceM = Double(d) / 10.0 } // 1/10 m
        out.isRunning = (flags & 0x04 != 0)
        return out
    }

    // MARK: - Cycling Speed and Cadence (0x2A5B)
    //
    // Flags (u8) then, IN ORDER:
    //   bit0  Wheel Revolution Data present → Cumulative Wheel Revolutions u32
    //                                       + Last Wheel Event Time u16 (1/1024 s)
    //   bit1  Crank Revolution Data present → Cumulative Crank Revolutions u16
    //                                       + Last Crank Event Time u16 (1/1024 s)
    public static func cyclingSpeedCadence(_ data: [UInt8]) -> FitnessSensorReading? {
        var r = Reader(bytes: data)
        guard let flags = r.u8() else { return nil }
        var out = FitnessSensorReading(kind: .cyclingSpeedCadence)

        if flags & 0x01 != 0 {                                       // Wheel Revolution Data
            if let w = r.u32() { out.cumulativeWheelRevolutions = w }
            if let t = r.u16() { out.lastWheelEventTime1024 = t }
        }
        if flags & 0x02 != 0 {                                       // Crank Revolution Data
            if let c = r.u16() { out.cumulativeCrankRevolutions = c }
            if let t = r.u16() { out.lastCrankEventTime1024 = t }
        }
        return out
    }

    // MARK: - Cycling Power Measurement (0x2A63)
    //
    // Flags (u16) then:
    //   —     Instantaneous Power            sint16, watts   (ALWAYS present)
    //   bit0  Pedal Power Balance present    → u8
    //   bit1  Pedal Power Balance Reference  → no field (a flag only)
    //   bit2  Accumulated Torque present     → u16
    //   bit3  Accumulated Torque Source      → no field (a flag only)
    //   bit4  Wheel Revolution Data present  → Cumulative Wheel Revolutions u32 + Last Wheel Event u16
    //                                          (NOTE: CPS wheel event time is 1/2048 s, unlike CSC's 1/1024)
    //   bit5  Crank Revolution Data present  → Cumulative Crank Revolutions u16 + Last Crank Event u16
    //   bit6  Extreme Force Magnitudes       → u16 + u16
    //   bit7  Extreme Torque Magnitudes      → u16 + u16
    //   bit8  Extreme Angles present         → u24 (two 12-bit angles packed)
    //   bit9  Top Dead Spot Angle present    → u16
    //   bit10 Bottom Dead Spot Angle present → u16
    //   bit11 Accumulated Energy present     → u16
    //   bit12 Offset Compensation Indicator  → no field (a flag only)
    public static func cyclingPower(_ data: [UInt8]) -> FitnessSensorReading? {
        var r = Reader(bytes: data)
        guard let flags = r.u16() else { return nil }
        var out = FitnessSensorReading(kind: .cyclingPower)

        if let p = r.s16() { out.instantaneousPowerWatts = p }       // Instantaneous Power (always present)
        if flags & 0x0001 != 0 { _ = r.u8() }                       // Pedal Power Balance
        if flags & 0x0004 != 0 { _ = r.u16() }                      // Accumulated Torque
        if flags & 0x0010 != 0 {                                     // Wheel Revolution Data
            if let w = r.u32() { out.cumulativeWheelRevolutions = w }
            if let t = r.u16() { out.lastWheelEventTime1024 = t }
        }
        if flags & 0x0020 != 0 {                                     // Crank Revolution Data
            if let c = r.u16() { out.cumulativeCrankRevolutions = c }
            if let t = r.u16() { out.lastCrankEventTime1024 = t }
        }
        if flags & 0x0040 != 0 { r.skip(4) }                        // Extreme Force Magnitudes (u16+u16)
        if flags & 0x0080 != 0 { r.skip(4) }                        // Extreme Torque Magnitudes (u16+u16)
        if flags & 0x0100 != 0 { _ = r.u24() }                      // Extreme Angles (u24)
        if flags & 0x0200 != 0 { _ = r.u16() }                      // Top Dead Spot Angle
        if flags & 0x0400 != 0 { _ = r.u16() }                      // Bottom Dead Spot Angle
        if flags & 0x0800 != 0 { _ = r.u16() }                      // Accumulated Energy
        return out
    }

    /// Decode whichever measurement by its 16-bit characteristic UUID short form (case-insensitive).
    /// Returns nil for an unknown UUID or an empty packet, so the caller can ignore it cleanly.
    public static func decode(uuid16: String, _ data: [UInt8]) -> FitnessSensorReading? {
        switch uuid16.uppercased() {
        case "2A53": return runningSpeedCadence(data)
        case "2A5B": return cyclingSpeedCadence(data)
        case "2A63": return cyclingPower(data)
        default:     return nil
        }
    }
}

// MARK: - Rate computer (derive instantaneous cadence/speed from CSC/CPS cumulative counters)

/// Turns successive CSC/CPS revolution counters into instantaneous wheel speed and crank/pedal cadence.
///
/// HONEST DERIVATION: CSC and CPS report only CUMULATIVE counts + the event time of the last revolution
/// (u16, wrapping at 65536). An instantaneous rate is the count difference over the time difference
/// between two packets — so the FIRST packet (nothing to diff against) and any packet that repeats the
/// same event time (the sensor hasn't ticked since) yield nil, never a fabricated value. Time wrap and
/// counter wrap (u32 wheel / u16 crank) are handled with modular arithmetic. Pure value type — no I/O —
/// so it's fully unit-tested.
///
/// TICK RATES (PR #1007): the wheel event-time clock is SOURCE-dependent — CSC (0x2A5B) ticks at
/// 1/1024 s but CPS (0x2A63) at 1/2048 s (Cycling Power Service 1.1, Wheel Revolution Data). A shared
/// 1024 divisor made a CPS wheel delta look twice as long as reality, HALVING CPS-derived speed. The
/// wheel path therefore selects the rate from `reading.kind` — and because a 2A5B↔2A63 flip means the
/// baseline timestamp sits on a DIFFERENT clock base, a kind flip drops the wheel baseline so the first
/// post-flip packet yields nil rather than a speed computed across mixed clocks. Crank event time is
/// 1/1024 s on BOTH profiles, so the crank path is unchanged.
public struct FitnessRateComputer: Sendable {

    /// Wheel circumference in metres, used to turn wheel revolutions into speed. The spec default road
    /// 700×25c tyre is ~2.105 m; exposed so a caller could let the user set it. Speed is only as honest
    /// as this number, so it's surfaced as an estimate.
    public var wheelCircumferenceM: Double

    private var lastWheelRevs: UInt32?
    private var lastWheelTime1024: Int?
    /// Which profile the wheel baseline came from. CSC and CPS wheel event times tick on DIFFERENT
    /// clock bases (1/1024 vs 1/2048 s), so a delta across a kind flip is meaningless — the baseline is
    /// dropped when the kind changes and the first post-flip packet re-seeds it (PR #1007).
    private var lastWheelKind: FitnessSensorKind?
    private var lastCrankRevs: Int?
    private var lastCrankTime1024: Int?

    public init(wheelCircumferenceM: Double = 2.105) {
        self.wheelCircumferenceM = wheelCircumferenceM
    }

    /// A computed instantaneous result from one update. Any field is nil when it couldn't be derived
    /// (first packet, no new revolution, or the relevant data block was absent from the packet).
    public struct Rates: Equatable, Sendable {
        /// Wheel speed in metres/second (CSC/CPS wheel data × circumference).
        public var speedMps: Double?
        /// Crank / pedal cadence in revolutions per minute (CSC crank data, CPS crank data).
        public var crankRpm: Double?
        public init(speedMps: Double? = nil, crankRpm: Double? = nil) {
            self.speedMps = speedMps; self.crankRpm = crankRpm
        }
        /// Speed in km/h, if derived.
        public var speedKmh: Double? { speedMps.map { $0 * 3.6 } }
    }

    /// Modular difference of two 1/1024-s event-time stamps, accounting for the 16-bit wrap at 65536.
    /// Returns the elapsed ticks in [0, 65536). 0 means "no time has passed" (same event) → no rate.
    private static func timeDelta1024(_ now: Int, _ prev: Int) -> Int {
        ((now - prev) % 65536 + 65536) % 65536
    }

    /// Fold one decoded reading in and return whatever instantaneous rates it lets us derive. Mutating —
    /// it remembers this packet's counters as the baseline for the next. Only the blocks present in the
    /// reading are used; the wheel path additionally tracks WHICH profile the baseline came from, because
    /// CSC and CPS wheel timestamps are not on the same clock base (see the type doc, PR #1007).
    public mutating func update(_ reading: FitnessSensorReading) -> Rates {
        var rates = Rates()

        // Wheel → speed.
        if let revs = reading.cumulativeWheelRevolutions, let time = reading.lastWheelEventTime1024 {
            // PR #1007: the wheel event-time tick rate is profile-specific — CSC (0x2A5B) 1/1024 s,
            // CPS (0x2A63) 1/2048 s. A shared /1024 halved CPS-derived speed. The 16-bit wrap in
            // timeDelta1024 is tick-count arithmetic, so only the seconds conversion branches.
            let wheelTicksPerSec: Double = reading.kind == .cyclingPower ? 2048.0 : 1024.0
            // A 2A5B↔2A63 kind flip puts the baseline timestamp on a DIFFERENT clock base; a cross-base
            // delta would fabricate a speed, so drop the baseline and let this packet re-seed it (the
            // first post-flip packet yields nil — same honesty rule as a true first packet).
            if lastWheelKind != reading.kind {
                lastWheelRevs = nil
                lastWheelTime1024 = nil
            }
            if let pRevs = lastWheelRevs, let pTime = lastWheelTime1024 {
                let dt = Self.timeDelta1024(time, pTime)
                if dt > 0 {
                    // u32 counter wrap handled by unsigned subtraction.
                    let dRev = Int(bitPattern: UInt(revs &- pRevs))
                    let seconds = Double(dt) / wheelTicksPerSec
                    rates.speedMps = Double(dRev) * wheelCircumferenceM / seconds
                }
            }
            lastWheelRevs = revs
            lastWheelTime1024 = time
            lastWheelKind = reading.kind
        }

        // Crank → cadence.
        if let revs = reading.cumulativeCrankRevolutions, let time = reading.lastCrankEventTime1024 {
            if let pRevs = lastCrankRevs, let pTime = lastCrankTime1024 {
                let dt = Self.timeDelta1024(time, pTime)
                if dt > 0 {
                    let dRev = ((revs - pRevs) % 65536 + 65536) % 65536   // u16 counter wrap
                    let minutes = (Double(dt) / 1024.0) / 60.0
                    rates.crankRpm = Double(dRev) / minutes
                }
            }
            lastCrankRevs = revs
            lastCrankTime1024 = time
        }

        return rates
    }

    /// Forget the baselines (call on disconnect / new session) so the next packet is treated as a first.
    public mutating func reset() {
        lastWheelRevs = nil; lastWheelTime1024 = nil; lastWheelKind = nil
        lastCrankRevs = nil; lastCrankTime1024 = nil
    }
}
