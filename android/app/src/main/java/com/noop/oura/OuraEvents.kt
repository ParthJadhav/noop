package com.noop.oura

// OuraEvents: the decoded value structs the driver emits (OURA_PROTOCOL.md s6). Kotlin twin of
// OuraEvents.swift. Each carries the record's ringTimestamp (the ring-clock value; the app anchors it
// to UTC via the 0x42 time-sync / 0x85 RTC events) plus the decoded signal. Pure value types, no
// android.bluetooth.
//
// DIVERGENCE FROM SWIFT: Swift's UInt32 ringTimestamp becomes a Long holding the unsigned 32-bit
// value (0..0xFFFFFFFF), and Swift's Int64 epoch becomes Long. Values and layouts are identical.
//
// Per-sample timestamps inside a record (IBI/temp/HRV/SpO2) walk backward from the event time by each
// sample's own duration (OURA_PROTOCOL.md s6); to stay platform-pure and avoid baking a clock model
// into the decoders, the structs carry the raw ring/sample offsets and let the app's mapping layer
// apply the anchor. Honest-data invariant: a short/malformed record decodes to null upstream, so
// these structs only ever hold real decoded values.

/** One decoded inter-beat interval (and optional amplitude), in milliseconds. */
data class OuraIBI(val ringTimestamp: Long, val ibiMs: Int, val amplitude: Int? = null)

/** One decoded heart-rate value in BPM (derived from a live-HR push IBI, OURA_PROTOCOL.md s5.6). */
data class OuraHR(val ringTimestamp: Long, val bpm: Int, val ibiMs: Int)

/**
 * One decoded HRV (RMSSD-derived) sample from the ring's own 0x5D tag (OURA_PROTOCOL.md s6.9).
 * NOOP also reconstructs RMSSD itself from the IBI streams for its own scoring; this is the ring's
 * open HRV tag, NOT Oura's encrypted readiness score.
 */
data class OuraHRV(val ringTimestamp: Long, val timeMs: Int, val b1: Int, val b2: Int)

/** One decoded SpO2 sample. `value` is the raw SpO2 reading; `unit` documents its scale. */
data class OuraSpO2(val ringTimestamp: Long, val value: Int, val unit: String = "raw")

/** One decoded skin-temperature sample in degrees C (value already / 100). */
data class OuraTemp(val ringTimestamp: Long, val celsius: Double)

/**
 * One decoded battery reading (OURA_PROTOCOL.md s6.10). `percent` is read at body[0]; `voltageMv`
 * is the [4..6] fallback estimate (fixture-validated per generation, may be null).
 */
data class OuraBattery(val percent: Int, val voltageMv: Int? = null, val charging: Boolean? = null)

/** Sleep phase code (OURA_PROTOCOL.md s6.12): 2-bit codes 0=awake, 1=light, 2=deep, 3=REM. */
enum class OuraSleepStage(val raw: Int) {
    AWAKE(0),
    LIGHT(1),
    DEEP(2),
    REM(3);

    companion object {
        private val byRaw = entries.associateBy { it.raw }
        fun fromRaw(raw: Int): OuraSleepStage? = byRaw[raw]
    }
}

/** One decoded sleep-phase code in order within a 0x4E/0x5A record (OURA_PROTOCOL.md s6.12). */
data class OuraSleepPhase(val ringTimestamp: Long, val index: Int, val stage: OuraSleepStage)

/** Motion state (OURA_PROTOCOL.md s6.13): 0 NO_MOTION, 1 RESTLESS, 2 TOSSING, 3 ACTIVE. */
enum class OuraMotionState(val raw: Int) {
    NO_MOTION(0),
    RESTLESS(1),
    TOSSING(2),
    ACTIVE(3);

    companion object {
        private val byRaw = entries.associateBy { it.raw }
        fun fromRaw(raw: Int): OuraMotionState? = byRaw[raw]
    }
}

/** One decoded motion-state code from a 0x6B motion_period record (OURA_PROTOCOL.md s6.13). */
data class OuraMotion(val ringTimestamp: Long, val index: Int, val state: OuraMotionState)

/** Device lifecycle state (OURA_PROTOCOL.md s6.15) decoded from a 0x45/0x53 record. */
data class OuraState(val ringTimestamp: Long, val stateCode: Int, val text: String? = null)

/** A UTC anchor / time-sync event (OURA_PROTOCOL.md s6.11): epoch ms + timezone offset seconds. */
data class OuraTimeSync(val ringTimestamp: Long, val epochMs: Long, val tzOffsetSeconds: Int)

/** A secondary 1-second-granularity RTC beacon (OURA_PROTOCOL.md s6.15, tag 0x85). */
data class OuraRtcBeacon(val ringTimestamp: Long, val unixSeconds: Long)

// MARK: - Tier-B (UNVERIFIED) decoded events

/**
 * A Tier-B sleep summary value (OURA_PROTOCOL.md s6.12). UNVERIFIED layout; carries the raw payload
 * bytes plus the tag so a fixture test can validate before scoring trusts it. The driver only emits
 * this when allowTierB is set, and it is never folded into scoring silently.
 */
data class OuraTierBSummary(
    val tag: Int,
    val ringTimestamp: Long,
    val rawPayload: IntArray,
    val kind: String,          // "sleep_summary" / "activity" / "real_steps" / "spo2_smoothed"
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OuraTierBSummary) return false
        return tag == other.tag && ringTimestamp == other.ringTimestamp &&
            rawPayload.contentEquals(other.rawPayload) && kind == other.kind
    }

    override fun hashCode(): Int {
        var h = tag
        h = 31 * h + ringTimestamp.hashCode()
        h = 31 * h + rawPayload.contentHashCode()
        h = 31 * h + kind.hashCode()
        return h
    }
}

/**
 * One decoded `0x50` activity_info record: a `state` code (activity-category; meaning unconfirmed)
 * plus a per-sample MET (metabolic-equivalent) series. THIRD-PARTY FORMULA (OURA_PROTOCOL.md s6.13,
 * [oura-rs] - clean-room fact citation, no code copied): plausible against six real Gen 3 captures
 * from PR #960's investigation (resting ~0.9 MET through a vigorous-activity burst at 7.4 MET, all
 * physiologically sane), but NOT independently ground-truth-validated against the Oura app's own
 * numbers. It therefore stays Tier B: emitted only behind `OuraDriver.allowTierB`, and NEVER folded
 * into `OuraStreamMapping`/`Streams`/scoring (steps stay honest - no step count is minted from MET).
 * Kotlin twin of the Swift `OuraActivityInfo` (met as List<Double> keeps structural equality).
 */
data class OuraActivityInfo(val ringTimestamp: Long, val state: Int, val met: List<Double>)

// MARK: - The emitted event union

/**
 * What OuraDriver.ingest(record:) emits. A single record can yield several events (e.g. an IBI+amp
 * record carries up to 6 IBIs). Tier-B events are wrapped in TierB (or ActivityInfo) and only emitted
 * when the driver is configured to allow them; they must never feed scoring without passing a
 * real-capture fixture.
 *
 * Kotlin twin of the Swift `OuraEvent` enum-with-associated-values, modelled as a sealed class.
 */
sealed class OuraEvent {
    data class Hr(val value: OuraHR) : OuraEvent()
    data class Ibi(val value: OuraIBI) : OuraEvent()
    data class Hrv(val value: OuraHRV) : OuraEvent()
    data class Spo2(val value: OuraSpO2) : OuraEvent()
    data class Temp(val value: OuraTemp) : OuraEvent()
    data class Battery(val value: OuraBattery) : OuraEvent()
    data class SleepPhaseEvent(val value: OuraSleepPhase) : OuraEvent()
    data class MotionEvent(val value: OuraMotion) : OuraEvent()
    data class StateEvent(val value: OuraState) : OuraEvent()
    data class TimeSyncEvent(val value: OuraTimeSync) : OuraEvent()
    data class RtcBeaconEvent(val value: OuraRtcBeacon) : OuraEvent()
    data class DebugTextEvent(val ringTimestamp: Long, val text: String) : OuraEvent()

    /**
     * A Tier-B (UNVERIFIED) decoded value. Gated behind OuraDriver.allowTierB. Per the brief's TIER
     * DISCIPLINE: do not let Tier B feed values silently.
     */
    data class TierB(val value: OuraTierBSummary) : OuraEvent()

    /**
     * A decoded `0x50` activity_info record (state + MET series). Still Tier-B (see [OuraActivityInfo]
     * doc) - split out of the raw-bytes [TierB] wrapper because this ONE tag has a plausible decode
     * formula, so an investigating consumer can log real MET numbers instead of hex. Same gate
     * (`allowTierB`), same discipline (never reaches `OuraStreamMapping`).
     */
    data class ActivityInfo(val value: OuraActivityInfo) : OuraEvent()

    /** True for Tier-B events, so a consumer can assert none leaked into a Tier-A-only sink. */
    val isTierB: Boolean get() = this is TierB || this is ActivityInfo
}
