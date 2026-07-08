import Foundation

// EventTags: the inner-event-record tag dictionary (the `type` byte of a TLV record, OURA_PROTOCOL.md
// s2.3 / s6). Every tag carries an explicit trust tier so Tier-B (UNVERIFIED) layouts can never feed
// values into scoring silently. Facts cited per OURA_PROTOCOL.md s6 / s7.3.

/// Decoder trust tier. Tier A is verified against the byte-for-byte corpus and ships live. Tier B is
/// attested by a single no-license / AI-generated doc and MUST pass a real-capture fixture before
/// scoring trusts it (the OuraDriver gates Tier-B emission behind an explicit flag). Per the brief's
/// TIER DISCIPLINE rule and OURA_PROTOCOL.md s7.3.
public enum TrustTier: String, Sendable, Equatable, Codable {
    case tierA   // verified, ship now
    case tierB   // UNVERIFIED, fixture-gate before use
}

/// The Oura inner-event-record tag. Raw value == the `type` byte (>= 0x41 per OURA_PROTOCOL.md s2.3).
/// Only the tags NOOP actually decodes are enumerated; an unknown byte decodes to nil (honest).
public enum OuraEventTag: UInt8, Sendable, CaseIterable, Codable {
    // --- Lifecycle / state (Tier A) ---
    case ringStart        = 0x41   // ring_start_ind, OURA_PROTOCOL.md s6.15
    case timeSync         = 0x42   // time-sync ind (primary UTC anchor), OURA_PROTOCOL.md s6.11
    case debugText        = 0x43   // debug_event ASCII, OURA_PROTOCOL.md s6.15
    case stateChange      = 0x45   // state_change_ind, OURA_PROTOCOL.md s6.15
    case wearEvent        = 0x53   // wear_event (same STATE enum), OURA_PROTOCOL.md s6.15
    case rtcBeacon        = 0x85   // rtc_beacon_ind, OURA_PROTOCOL.md s6.15

    // --- HR / IBI (Tier A) ---
    case ibiAmplitude     = 0x60   // ibi_and_amplitude_event (bit-packed), OURA_PROTOCOL.md s6.1
    case greenIbiAmp      = 0x71   // green_ibi_and_amp_event, OURA_PROTOCOL.md s6.2
    case spo2IbiAmplitude = 0x6E   // spo2_ibi_and_amplitude_event (REVERSE byte order), OURA_PROTOCOL.md s6.3
    case greenIbiQuality  = 0x80   // green_ibi_quality_event (bit-packed across bytes), OURA_PROTOCOL.md s6.4
    case ibi              = 0x44   // ibi event (Tier-A IBI tag per the brief), OURA_PROTOCOL.md s6 / s0

    // --- HRV / RMSSD (Tier A) ---
    case hrvRmssd         = 0x5D   // hrv_event (ring's own RMSSD-derived HRV), OURA_PROTOCOL.md s6.9

    // --- SpO2 (Tier A) ---
    case spo2PerSample    = 0x6F   // spo2_event per-second, OURA_PROTOCOL.md s6.5
    case spo2Stable       = 0x7B   // spo2_stable_event (uint16 BIG-endian), OURA_PROTOCOL.md s6.6
    case spo2Dc           = 0x77   // spo2_dc_event (sign-magnitude deltas), OURA_PROTOCOL.md s6.7

    // --- Temperature (Tier A) ---
    case temp             = 0x46   // temp_event (int16 LE / 100), OURA_PROTOCOL.md s6.8
    case tempPeriod       = 0x69   // temp_period (single int16 LE / 100), OURA_PROTOCOL.md s6.8
    case sleepTemp        = 0x75   // sleep_temp_event (uint16 LE / 100), OURA_PROTOCOL.md s6.8

    // --- Motion (Tier A) ---
    case motion           = 0x47   // motion_events, OURA_PROTOCOL.md s6.13
    case motionPeriod     = 0x6B   // motion_period (2-bit MOTION_STATE codes), OURA_PROTOCOL.md s6.13

    // --- Battery (Tier A; carried inline, not a TLV record but routed here for the enum) ---
    // Battery (0x0D) is an OUTER command response, not a TLV inner record; see Decoders.decodeBattery.

    // --- Sleep summaries (Tier B, UNVERIFIED) ---
    case sleepSummary1    = 0x49   // sleep_summary_1, OURA_PROTOCOL.md s6.12 (UNVERIFIED)
    case sleepSummaryB    = 0x4B   // sleep summary variant, OURA_PROTOCOL.md s6.12 (UNVERIFIED)
    case sleepSummaryC    = 0x4C   // sleep summary variant, OURA_PROTOCOL.md s6.12 (UNVERIFIED)
    case sleepSummaryD    = 0x4F   // sleep summary variant, OURA_PROTOCOL.md s6.12 (UNVERIFIED)
    case sleepSummaryE    = 0x57   // sleep summary variant, OURA_PROTOCOL.md s6.12 (UNVERIFIED)
    case sleepSummaryF    = 0x58   // sleep summary variant, OURA_PROTOCOL.md s6.12 (UNVERIFIED)

    // --- Sleep phase codes (Tier A: 2-bit phase codes are byte-for-byte verified) ---
    case sleepPhase       = 0x4E   // sleep_phase_details (2-bit codes), OURA_PROTOCOL.md s6.12
    case sleepPhaseAlt    = 0x5A   // sleep_phase_details alias, OURA_PROTOCOL.md s6.12

    // --- Activity / MET (Tier B, UNVERIFIED) ---
    case activityInfo     = 0x50   // activity_info (MET-class), OURA_PROTOCOL.md s6.13 (UNVERIFIED)
    case activitySummary1 = 0x51   // activity_summary, OURA_PROTOCOL.md s6.13 (UNVERIFIED)
    case activitySummary2 = 0x52   // activity_summary, OURA_PROTOCOL.md s6.13 (UNVERIFIED)

    // --- Real steps (Tier B, UNVERIFIED) ---
    case realSteps1       = 0x7E   // real_steps_features_1, OURA_PROTOCOL.md s6.13 (UNVERIFIED)
    case realSteps2       = 0x7F   // real_steps_features_2, OURA_PROTOCOL.md s6.13 (UNVERIFIED)

    // --- Smoothed SpO2 (Tier B, UNVERIFIED) ---
    case spo2Smoothed     = 0x70   // spo2_smoothed, OURA_PROTOCOL.md s6.6 (UNVERIFIED)

    /// The trust tier for this tag. Tier B tags are decoded but the OuraDriver gates their emission
    /// behind an explicit allowTierB flag. Per OURA_PROTOCOL.md s7.3 and the brief's TIER DISCIPLINE.
    public var tier: TrustTier {
        switch self {
        case .sleepSummary1, .sleepSummaryB, .sleepSummaryC, .sleepSummaryD, .sleepSummaryE,
             .sleepSummaryF, .activityInfo, .activitySummary1, .activitySummary2,
             .realSteps1, .realSteps2, .spo2Smoothed:
            return .tierB
        default:
            return .tierA
        }
    }

    /// A short, stable, human-facing name for the tag (used by the CLI dump and event kinds).
    public var name: String {
        switch self {
        case .ringStart: return "RING_START"
        case .timeSync: return "TIME_SYNC"
        case .debugText: return "DEBUG_TEXT"
        case .stateChange: return "STATE_CHANGE"
        case .wearEvent: return "WEAR_EVENT"
        case .rtcBeacon: return "RTC_BEACON"
        case .ibiAmplitude: return "IBI_AMPLITUDE"
        case .greenIbiAmp: return "GREEN_IBI_AMP"
        case .spo2IbiAmplitude: return "SPO2_IBI_AMPLITUDE"
        case .greenIbiQuality: return "GREEN_IBI_QUALITY"
        case .ibi: return "IBI"
        case .hrvRmssd: return "HRV_RMSSD"
        case .spo2PerSample: return "SPO2_PER_SAMPLE"
        case .spo2Stable: return "SPO2_STABLE"
        case .spo2Dc: return "SPO2_DC"
        case .temp: return "TEMP"
        case .tempPeriod: return "TEMP_PERIOD"
        case .sleepTemp: return "SLEEP_TEMP"
        case .motion: return "MOTION"
        case .motionPeriod: return "MOTION_PERIOD"
        case .sleepSummary1: return "SLEEP_SUMMARY_1"
        case .sleepSummaryB: return "SLEEP_SUMMARY_4B"
        case .sleepSummaryC: return "SLEEP_SUMMARY_4C"
        case .sleepSummaryD: return "SLEEP_SUMMARY_4F"
        case .sleepSummaryE: return "SLEEP_SUMMARY_57"
        case .sleepSummaryF: return "SLEEP_SUMMARY_58"
        case .sleepPhase: return "SLEEP_PHASE"
        case .sleepPhaseAlt: return "SLEEP_PHASE_ALT"
        case .activityInfo: return "ACTIVITY_INFO"
        case .activitySummary1: return "ACTIVITY_SUMMARY_1"
        case .activitySummary2: return "ACTIVITY_SUMMARY_2"
        case .realSteps1: return "REAL_STEPS_1"
        case .realSteps2: return "REAL_STEPS_2"
        case .spo2Smoothed: return "SPO2_SMOOTHED"
        }
    }
}
