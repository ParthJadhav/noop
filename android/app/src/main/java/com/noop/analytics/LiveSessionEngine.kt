package com.noop.analytics

// LiveSessionEngine.kt — the "silent guardian" coach for a Live Session. Pure, deterministic, DB-free.
// Byte-for-byte mirror of Strand/Packages/StrandAnalytics/Sources/StrandAnalytics/LiveSessionEngine.swift.
//
// Watches a live heart-rate stream against a recovery-gated target BAND and emits at most two haptic cues:
// a gentle PUSH nudge when you drift too easy for today, and a firmer EASE-OFF when you push harder than
// today's recovery can pay for. Silence means you are on track — the whole point.
//
// A single instance per session; time is passed in on every update(now, bpm) so a session replays
// deterministically from a synthetic HR trace with no clock, no BLE, no UI. The GOLDEN VECTORS in
// LiveSessionEngineTest mirror LiveSessionEngineTests.swift exactly — the cross-platform parity contract.
// Design contract: docs/superpowers/specs/2026-07-04-live-sessions-design.md.
//
//   1. A WRONG buzz is unforgivable; a MISSED buzz is fine → bias hard toward silence (dwell/cool-down/hysteresis).
//   2. Never fabricate → impossible samples rejected before they can cue; a stale stream pauses coaching.
class LiveSessionEngine(private val config: Config, private val startTs: Int) {

    companion object {
        // ── Tuning constants (pinned by test; mirror the Swift twin exactly) ──
        const val ceilingPctAtLowCharge: Double = 0.60
        const val ceilingPctAtHighCharge: Double = 0.82
        const val bandWidthPctHRR: Double = 0.15
        const val minFloorPctHRR: Double = 0.40
        const val defaultChargeFraction: Double = 0.5

        const val smoothingWindowSec: Int = 12
        const val staleAfterSec: Int = 8
        const val warmupSec: Int = 60
        const val climbGraceSec: Int = 45

        const val dwellSec: Int = 25
        const val cooldownSec: Int = 50
        const val hysteresisMarginBpm: Double = 2.0
        const val maxAccrualDtSec: Int = 5

        const val stepChangeBpm: Double = 8.0
        const val stepChangeWindowSec: Int = 15
        const val climbAttributionSec: Int = 20

        const val ceilingDriftAfterSec: Int = 90
        const val ceilingDriftStepBpm: Double = 2.0
        const val ceilingDriftMaxBpm: Double = 8.0

        const val minPlausibleBpm: Double = 25.0
        const val aboveHRmaxRejectBpm: Double = 5.0
        const val maxJumpBpm: Double = 45.0

        /** The recovery-gated target band. Charge scales the ceiling; the floor sits a fixed HRR width below. */
        fun band(config: Config): Band {
            val cn = config.charge?.let { (it / 100.0).coerceIn(0.0, 1.0) } ?: defaultChargeFraction
            val ceilingPct = ceilingPctAtLowCharge + (ceilingPctAtHighCharge - ceilingPctAtLowCharge) * cn
            val floorPct = maxOf(ceilingPct - bandWidthPctHRR, minFloorPctHRR)
            val reserve = maxOf(config.hrMax - config.restingHR, 1.0)
            return Band(
                floorBpm = config.restingHR + floorPct * reserve,
                ceilingBpm = config.restingHR + ceilingPct * reserve,
                floorPctHRR = floorPct,
                ceilingPctHRR = ceilingPct,
            )
        }
    }

    data class Config(val restingHR: Double, val hrMax: Double, val charge: Double?)

    data class Band(
        val floorBpm: Double,
        val ceilingBpm: Double,
        val floorPctHRR: Double,
        val ceilingPctHRR: Double,
    )

    enum class Status(val raw: String) { WARMUP("warmup"), ACTIVE("active"), STALE("stale") }
    enum class Position(val raw: String) { BELOW("below"), IN_BAND("inBand"), ABOVE("above") }
    enum class Cue(val raw: String) { PUSH_NUDGE("pushNudge"), EASE_OFF("easeOff") }

    data class Output(
        val status: Status,
        val position: Position,
        val smoothedBpm: Double?,
        val band: Band,
        val inBandSeconds: Double,
        val sampleArrived: Boolean,
        val cue: Cue?,
    )

    // ── State ──
    private data class Reading(val ts: Int, val bpm: Int)
    private val baseBand: Band = band(config)
    private val buffer = mutableListOf<Reading>()
    private val smoothedHistory = mutableListOf<Pair<Int, Double>>()

    private var lastUpdateTs: Int = startTs
    private var lastValidTs: Int? = null
    private var lastAcceptedBpm: Double? = null
    private var currentPosition: Position = Position.IN_BAND
    private var inBandSeconds: Double = 0.0

    private var belowSinceTs: Int? = null
    private var aboveSinceTs: Int? = null
    private var aboveSlowSinceTs: Int? = null
    private var lastClimbTs: Int? = null
    private var lastPushCueTs: Int? = null
    private var lastEaseCueTs: Int? = null
    private var ceilingDriftBpm: Double = 0.0

    /** Advance to `now`. Pass the live bpm if one arrived, or null for a plain time tick (staleness check). */
    fun update(now: Int, bpm: Int?): Output {
        val dt = maxOf(now - lastUpdateTs, 0)

        // 1. Validate + accept the sample (never-fabricate guard).
        var sampleArrived = false
        if (bpm != null && isPlausible(bpm.toDouble(), now)) {
            buffer.add(Reading(now, bpm))
            lastValidTs = now
            lastAcceptedBpm = bpm.toDouble()
            sampleArrived = true
        }

        // 2. Prune the smoothing window and compute the trend.
        val windowStart = now - smoothingWindowSec
        buffer.removeAll { it.ts < windowStart }
        val smoothed = if (buffer.isEmpty()) null else median(buffer.map { it.bpm.toDouble() })

        // 3. Staleness — coaching pauses, nothing accrues, dwell freezes.
        val sinceValid = lastValidTs?.let { now - it } ?: (now - startTs)
        val isStale = sinceValid > staleAfterSec
        val band = currentBand()

        if (isStale || smoothed == null) {
            lastUpdateTs = now
            return Output(Status.STALE, currentPosition, null, band, inBandSeconds, sampleArrived, null)
        }
        val s = smoothed

        // 4. Step-change (sharp-climb) detection off the smoothed trend.
        smoothedHistory.add(now to s)
        smoothedHistory.removeAll { it.first < now - stepChangeWindowSec - 2 }
        val past = smoothedHistory.firstOrNull { now - it.first >= stepChangeWindowSec }
        if (past != null && s - past.second >= stepChangeBpm) {
            lastClimbTs = now
        }

        // 5. Classify against the band with hysteresis.
        val newPosition = classify(s, band, currentPosition)

        // 6. Dwell trackers.
        when (newPosition) {
            Position.BELOW -> {
                if (currentPosition != Position.BELOW) belowSinceTs = now
                aboveSinceTs = null; aboveSlowSinceTs = null
            }
            Position.ABOVE -> {
                if (currentPosition != Position.ABOVE) {
                    aboveSinceTs = now
                    val fromClimb = lastClimbTs?.let { now - it <= climbAttributionSec } ?: false
                    aboveSlowSinceTs = if (fromClimb) null else now
                }
                belowSinceTs = null
            }
            Position.IN_BAND -> {
                belowSinceTs = null; aboveSinceTs = null; aboveSlowSinceTs = null
            }
        }

        // 7. Accrue in-band time (dt clamped so a stall can't inflate the ring).
        if (newPosition == Position.IN_BAND) {
            inBandSeconds += minOf(dt, maxAccrualDtSec).toDouble()
        }

        // 8. Status.
        val status = if (now - startTs < warmupSec) Status.WARMUP else Status.ACTIVE

        // 9. Cue decision — only when active, one cue at most, silence by default.
        var cue: Cue? = null
        if (status == Status.ACTIVE) {
            val below = belowSinceTs
            val above = aboveSinceTs
            if (newPosition == Position.BELOW && below != null && now - below >= dwellSec &&
                (lastPushCueTs?.let { now - it >= cooldownSec } ?: true) &&
                (lastClimbTs?.let { now - it >= climbGraceSec } ?: true)
            ) {
                cue = Cue.PUSH_NUDGE
                lastPushCueTs = now
                belowSinceTs = now
            } else if (newPosition == Position.ABOVE && above != null && now - above >= dwellSec &&
                (lastEaseCueTs?.let { now - it >= cooldownSec } ?: true) &&
                aboveSlowSinceTs == null   // only a step-change breach earns an ease-off
            ) {
                cue = Cue.EASE_OFF
                lastEaseCueTs = now
                aboveSinceTs = now
            }
        }

        // 10. Ceiling drift — adapt (bounded) to a genuinely strong, slow-drift day.
        val slowSince = aboveSlowSinceTs
        if (newPosition == Position.ABOVE && slowSince != null &&
            now - slowSince >= ceilingDriftAfterSec && ceilingDriftBpm < ceilingDriftMaxBpm
        ) {
            ceilingDriftBpm = minOf(ceilingDriftBpm + ceilingDriftStepBpm, ceilingDriftMaxBpm)
            aboveSlowSinceTs = now
        }

        currentPosition = newPosition
        lastUpdateTs = now
        return Output(status, newPosition, s, band, inBandSeconds, sampleArrived, cue)
    }

    // ── Internals ──

    private fun currentBand(): Band {
        if (ceilingDriftBpm == 0.0) return baseBand
        val reserve = maxOf(config.hrMax - config.restingHR, 1.0)
        val ceilingBpm = baseBand.ceilingBpm + ceilingDriftBpm
        return Band(baseBand.floorBpm, ceilingBpm, baseBand.floorPctHRR, (ceilingBpm - config.restingHR) / reserve)
    }

    private fun isPlausible(bpm: Double, now: Int): Boolean {
        if (bpm < minPlausibleBpm) return false
        if (bpm > config.hrMax + aboveHRmaxRejectBpm) return false
        val last = lastAcceptedBpm
        val lastTs = lastValidTs
        if (last != null && lastTs != null && now - lastTs <= smoothingWindowSec &&
            kotlin.math.abs(bpm - last) > maxJumpBpm
        ) {
            return false
        }
        return true
    }

    private fun classify(s: Double, band: Band, previous: Position): Position {
        val m = hysteresisMarginBpm
        if (s > band.ceilingBpm + m) return Position.ABOVE
        if (s < band.floorBpm - m) return Position.BELOW
        if (s >= band.floorBpm + m && s <= band.ceilingBpm - m) return Position.IN_BAND
        return previous // inside the margin zone: hold, don't flicker
    }

    private fun median(xs: List<Double>): Double {
        val sorted = xs.sorted()
        val n = sorted.size
        if (n == 0) return 0.0
        return if (n % 2 == 1) sorted[n / 2] else (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }
}
