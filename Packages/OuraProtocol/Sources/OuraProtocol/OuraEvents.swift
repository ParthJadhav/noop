import Foundation

// OuraEvents: the decoded value structs the driver emits (OURA_PROTOCOL.md s6). Each carries the
// record's ringTimestamp (the ring-clock value; the app anchors it to UTC via the 0x42 time-sync /
// 0x85 RTC events) plus the decoded signal. Pure value types, no CoreBluetooth.
//
// Per-sample timestamps inside a record (IBI/temp/HRV/SpO2) walk backward from the event time by each
// sample's own duration (OURA_PROTOCOL.md s6); to stay platform-pure and avoid baking a clock model
// into the decoders, the structs carry the raw ring/sample offsets and let the app's mapping layer
// (OuraStreamMapping) apply the anchor. Honest-data invariant: a short/malformed record decodes to
// nil upstream, so these structs only ever hold real decoded values.

/// One decoded inter-beat interval (and optional amplitude), in milliseconds.
public struct OuraIBI: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let ibiMs: Int
    public let amplitude: Int?
    public init(ringTimestamp: UInt32, ibiMs: Int, amplitude: Int? = nil) {
        self.ringTimestamp = ringTimestamp; self.ibiMs = ibiMs; self.amplitude = amplitude
    }
}

/// One decoded heart-rate value in BPM (derived from a live-HR push IBI, OURA_PROTOCOL.md s5.6).
public struct OuraHR: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let bpm: Int
    public let ibiMs: Int
    public init(ringTimestamp: UInt32, bpm: Int, ibiMs: Int) {
        self.ringTimestamp = ringTimestamp; self.bpm = bpm; self.ibiMs = ibiMs
    }
}

/// One decoded HRV (RMSSD-derived) sample from the ring's own 0x5D tag (OURA_PROTOCOL.md s6.9).
/// NOOP also reconstructs RMSSD itself from the IBI streams for its own scoring; this is the ring's
/// open HRV tag, NOT Oura's encrypted readiness score.
public struct OuraHRV: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let timeMs: Int
    public let b1: Int
    public let b2: Int
    public init(ringTimestamp: UInt32, timeMs: Int, b1: Int, b2: Int) {
        self.ringTimestamp = ringTimestamp; self.timeMs = timeMs; self.b1 = b1; self.b2 = b2
    }
}

/// One decoded SpO2 sample. `value` is the raw SpO2 reading; `unit` documents its scale.
public struct OuraSpO2: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let value: Int
    public let unit: String
    public init(ringTimestamp: UInt32, value: Int, unit: String = "raw") {
        self.ringTimestamp = ringTimestamp; self.value = value; self.unit = unit
    }
}

/// One decoded skin-temperature sample in hundredths of a degree C scaled to C (value already / 100).
public struct OuraTemp: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let celsius: Double
    public init(ringTimestamp: UInt32, celsius: Double) {
        self.ringTimestamp = ringTimestamp; self.celsius = celsius
    }
}

/// One decoded battery reading (OURA_PROTOCOL.md s6.10). `percent` is read at body[0]; `voltageMv`
/// is the [4..6] fallback estimate (fixture-validated per generation, may be nil).
public struct OuraBattery: Equatable, Sendable, Codable {
    public let percent: Int
    public let voltageMv: Int?
    public let charging: Bool?
    public init(percent: Int, voltageMv: Int? = nil, charging: Bool? = nil) {
        self.percent = percent; self.voltageMv = voltageMv; self.charging = charging
    }
}

/// Sleep phase code (OURA_PROTOCOL.md s6.12): 2-bit codes 0=awake, 1=light, 2=deep, 3=REM.
public enum OuraSleepStage: Int, Sendable, Equatable, Codable {
    case awake = 0
    case light = 1
    case deep = 2
    case rem = 3
}

/// One decoded sleep-phase code in order within a 0x4E/0x5A record (OURA_PROTOCOL.md s6.12).
public struct OuraSleepPhase: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let index: Int          // position within the record's phase sequence
    public let stage: OuraSleepStage
    public init(ringTimestamp: UInt32, index: Int, stage: OuraSleepStage) {
        self.ringTimestamp = ringTimestamp; self.index = index; self.stage = stage
    }
}

/// Motion state (OURA_PROTOCOL.md s6.13): 0 NO_MOTION, 1 RESTLESS, 2 TOSSING, 3 ACTIVE.
public enum OuraMotionState: Int, Sendable, Equatable, Codable {
    case noMotion = 0
    case restless = 1
    case tossing = 2
    case active = 3
}

/// One decoded motion-state code from a 0x6B motion_period record (OURA_PROTOCOL.md s6.13).
public struct OuraMotion: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let index: Int
    public let state: OuraMotionState
    public init(ringTimestamp: UInt32, index: Int, state: OuraMotionState) {
        self.ringTimestamp = ringTimestamp; self.index = index; self.state = state
    }
}

/// Device lifecycle state (OURA_PROTOCOL.md s6.15) decoded from a 0x45/0x53 record.
public struct OuraState: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let stateCode: Int
    public let text: String?
    public init(ringTimestamp: UInt32, stateCode: Int, text: String? = nil) {
        self.ringTimestamp = ringTimestamp; self.stateCode = stateCode; self.text = text
    }
}

/// A UTC anchor / time-sync event (OURA_PROTOCOL.md s6.11): epoch ms + timezone offset seconds.
public struct OuraTimeSync: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let epochMs: Int64
    public let tzOffsetSeconds: Int
    public init(ringTimestamp: UInt32, epochMs: Int64, tzOffsetSeconds: Int) {
        self.ringTimestamp = ringTimestamp; self.epochMs = epochMs; self.tzOffsetSeconds = tzOffsetSeconds
    }
}

/// A secondary 1-second-granularity RTC beacon (OURA_PROTOCOL.md s6.15, tag 0x85).
public struct OuraRtcBeacon: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let unixSeconds: Int
    public init(ringTimestamp: UInt32, unixSeconds: Int) {
        self.ringTimestamp = ringTimestamp; self.unixSeconds = unixSeconds
    }
}

// MARK: - Tier-B (UNVERIFIED) decoded events

/// A Tier-B sleep summary value (OURA_PROTOCOL.md s6.12). UNVERIFIED layout; carries the raw payload
/// bytes plus the tag so a fixture test can validate before scoring trusts it. The driver only emits
/// this when allowTierB is set, and it is never folded into scoring silently.
public struct OuraTierBSummary: Equatable, Sendable, Codable {
    public let tag: UInt8
    public let ringTimestamp: UInt32
    public let rawPayload: [UInt8]
    public let kind: String        // "sleep_summary" / "activity" / "real_steps" / "spo2_smoothed"
    public init(tag: UInt8, ringTimestamp: UInt32, rawPayload: [UInt8], kind: String) {
        self.tag = tag; self.ringTimestamp = ringTimestamp; self.rawPayload = rawPayload; self.kind = kind
    }
}

/// One decoded `0x50` activity_info record: a `state` code (activity-category; meaning unconfirmed)
/// plus a per-sample MET (metabolic-equivalent) series. THIRD-PARTY FORMULA (OURA_PROTOCOL.md s6.13,
/// [oura-rs] - clean-room fact citation, no code copied): plausible against six real Gen 3 captures
/// from PR #960's investigation (resting ~0.9 MET through a vigorous-activity burst at 7.4 MET, all
/// physiologically sane), but NOT independently ground-truth-validated against the Oura app's own
/// numbers. It therefore stays Tier B: emitted only behind `OuraDriver.allowTierB`, and NEVER folded
/// into `OuraStreamMapping`/`Streams`/scoring (steps stay honest - no step count is minted from MET).
public struct OuraActivityInfo: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let state: Int
    public let met: [Double]
    public init(ringTimestamp: UInt32, state: Int, met: [Double]) {
        self.ringTimestamp = ringTimestamp; self.state = state; self.met = met
    }
}

// MARK: - The emitted event union

/// What OuraDriver.ingest(record:) emits. A single record can yield several events (e.g. an IBI+amp
/// record carries up to 6 IBIs). Tier-B events are wrapped in .tierB (or .activityInfo) and only
/// emitted when the driver is configured to allow them; they must never feed scoring without passing
/// a real-capture fixture.
public enum OuraEvent: Equatable, Sendable {
    case hr(OuraHR)
    case ibi(OuraIBI)
    case hrv(OuraHRV)
    case spo2(OuraSpO2)
    case temp(OuraTemp)
    case battery(OuraBattery)
    case sleepPhase(OuraSleepPhase)
    case motion(OuraMotion)
    case state(OuraState)
    case timeSync(OuraTimeSync)
    case rtcBeacon(OuraRtcBeacon)
    case debugText(ringTimestamp: UInt32, text: String)
    /// A Tier-B (UNVERIFIED) decoded value. Gated behind OuraDriver.allowTierB. Per the brief's TIER
    /// DISCIPLINE: do not let Tier B feed values silently.
    case tierB(OuraTierBSummary)
    /// A decoded `0x50` activity_info record (state + MET series). Still Tier-B (see `OuraActivityInfo`
    /// doc) - split out of the raw-bytes `.tierB` wrapper because this ONE tag has a plausible decode
    /// formula, so an investigating consumer can log real MET numbers instead of hex. Same gate
    /// (`allowTierB`), same discipline (never reaches `OuraStreamMapping`).
    case activityInfo(OuraActivityInfo)

    /// True for Tier-B events, so a consumer can assert none leaked into a Tier-A-only sink.
    public var isTierB: Bool {
        switch self {
        case .tierB, .activityInfo: return true
        default: return false
        }
    }
}
