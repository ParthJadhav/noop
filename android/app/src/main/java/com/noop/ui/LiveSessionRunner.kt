package com.noop.ui

import android.content.Context
import com.noop.analytics.LiveSessionEngine
import com.noop.data.LiveSessionRow
import com.noop.protocol.LiveSessionHaptics
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.LocalDate

// MARK: - LiveSessionRunner — the Live Session controller ("silent guardian" v1)
//
// The thin, impure shell around the pure [LiveSessionEngine]: a 1 Hz coroutine tick feeds the engine
// wall-clock + the most-recent live bpm, publishes the engine's Output (plus elapsed/cue/accrual state)
// for the session screen, walks a cue's [LiveSessionHaptics] pulse list out through the EXISTING strap
// buzz, and upserts the session's [LiveSessionRow] at start (endTs null) and again at end (totals).
// Design contract: docs/superpowers/specs/2026-07-04-live-sessions-design.md.
//
// Every side effect comes in as a closure (read-bpm / buzz / persist / realtime-HR arming), the same
// dependency style StandardHrSource uses (liveSink/persist), so the runner is constructible in a JVM
// test with fakes and no Android framework. The engine stays the single source of coaching truth —
// the runner never invents a cue, never re-times one, and drops (never queues) a cue whose predecessor
// is still buzzing out, so the wrist can never receive a stale or stacked signal.
//
// LIFETIME: one runner per session, held process-visible in [LiveSessionRunner.active] so dismissing
// the session dialog does NOT end the session (wrist-first: the guardian keeps coaching; Today's entry
// card becomes the way back in). The tick runs on the caller-supplied scope (the app-wide
// AppViewModel's viewModelScope at the call site), so a process death simply ends the session — the
// start row (endTs null) is already banked and reads honestly as an unfinished session.
class LiveSessionRunner(
    val config: LiveSessionEngine.Config,
    val deviceId: String,
    private val scope: CoroutineScope,
    /** Most-recent live bpm, or null when none is current — [com.noop.ble.LiveState.heartRate]. */
    private val readBpm: () -> Int?,
    /** Fire one hardware buzz with the given stacked-loop count — [com.noop.ble.WhoopBleClient.buzz]. */
    private val buzz: (Int) -> Unit,
    /** Upsert the session row (start + end) — [com.noop.data.WhoopRepository.upsertLiveSession]. */
    private val persist: suspend (LiveSessionRow) -> Unit,
    /** Arm (true) / release (false) the ref-counted realtime HR stream around the session. */
    private val realtimeHr: (Boolean) -> Unit,
    /** Provenance token stored on the row (which live source fed the session). */
    private val hrSource: String = "whoop",
    /** Injectable clock (epoch seconds) so the tick/accrual/auto-end logic is testable. */
    private val nowEpochSec: () -> Long = { System.currentTimeMillis() / 1000L },
) {

    /** Everything the session screen renders, published once per tick (and once on end). */
    data class Snapshot(
        val output: LiveSessionEngine.Output?,
        val elapsedSec: Int,
        val pushCount: Int,
        val easeCount: Int,
        val belowSec: Double,
        val aboveSec: Double,
        val ended: Boolean,
        val endedAutomatically: Boolean,
    )

    /** Session start (epoch seconds) — the row's natural key alongside [deviceId]. */
    val startTs: Long = nowEpochSec()

    /** The recovery-gated band the session opened with (the row stores this start band). */
    val band: LiveSessionEngine.Band = LiveSessionEngine.band(config)

    private val engine = LiveSessionEngine(config, startTs.toInt())

    private val _snapshot = MutableStateFlow(
        Snapshot(
            output = null, elapsedSec = 0, pushCount = 0, easeCount = 0,
            belowSec = 0.0, aboveSec = 0.0, ended = false, endedAutomatically = false,
        ),
    )
    val snapshot: StateFlow<Snapshot> = _snapshot.asStateFlow()

    private var tickJob: Job? = null
    private var walkJob: Job? = null
    private var lastTickTs: Long = startTs
    private var endTs: Long? = null
    private var ended = false
    private var endedAutomatically = false

    // Out-of-band accrual (the engine only accrues IN-BAND time itself). dt is clamped to the engine's
    // own maxAccrualDtSec so a stalled tick (doze, background throttling) can't inflate the totals —
    // the same honesty rule the engine applies to the in-band ring.
    private var belowSec = 0.0
    private var aboveSec = 0.0
    private var pushCount = 0
    private var easeCount = 0

    // Continuous-STALE run length; at AUTO_END_AFTER_STALE_SEC the session ends itself (the strap left,
    // the guardian has nothing honest to guard). Any accepted sample resets it.
    private var staleRunSec = 0

    /** Begin the session: arm the realtime HR stream, bank the start row (endTs null), start the tick. */
    fun start() {
        if (tickJob != null || ended) return
        realtimeHr(true)
        scope.launch { runCatching { persist(openRow()) } }
        tickJob = scope.launch {
            while (isActive) {
                tick()
                delay(1_000L)
            }
        }
    }

    /** End the session: stop the tick, stop scheduling haptic pulses, release the HR stream, bank the
     *  totals row, and publish the final snapshot (ended = true → the screen shows the summary). */
    fun end(auto: Boolean = false) {
        if (ended) return
        ended = true
        endedAutomatically = auto
        tickJob?.cancel(); tickJob = null
        // Stop scheduling NEW pulses; a hardware buzz already in flight can't be recalled (see
        // WhoopBleClient.stopHaptics) and a cue walk is under ~4s, so cutting the schedule is enough.
        walkJob?.cancel(); walkJob = null
        realtimeHr(false)
        endTs = nowEpochSec()
        publish()
        scope.launch { runCatching { persist(closedRow()) } }
    }

    // ── Internals ──

    private fun tick() {
        if (ended) return
        val now = nowEpochSec()
        val dt = (now - lastTickTs).coerceAtLeast(0L).toInt()
        lastTickTs = now

        val out = engine.update(now.toInt(), readBpm())

        if (out.status == LiveSessionEngine.Status.STALE) {
            // Never fabricate: a stale stream accrues nothing and coaches nothing (the engine already
            // returns no cue); we only count how long the silence has run for the auto-end.
            staleRunSec += dt
        } else {
            staleRunSec = 0
            val accrual = minOf(dt, LiveSessionEngine.maxAccrualDtSec).toDouble()
            when (out.position) {
                LiveSessionEngine.Position.BELOW -> belowSec += accrual
                LiveSessionEngine.Position.ABOVE -> aboveSec += accrual
                LiveSessionEngine.Position.IN_BAND -> Unit // the engine accrues in-band time itself
            }
        }

        out.cue?.let { fireCue(it) }
        publish(out)

        if (staleRunSec >= AUTO_END_AFTER_STALE_SEC) end(auto = true)
    }

    /**
     * Walk the cue's pulse list out through the strap buzz — LONG pulse = heavier 2-loop, SHORT = light
     * 1-loop, each scheduled at its (durationMs + gapMs) spacing, the same weighting the Haptic Clock
     * trigger uses. DROP-TOLERANT: if a walk is still in flight the new cue is skipped entirely (never
     * queued) — the engine's 50s cooldown makes an overlap near-impossible, but a dropped cue is fine
     * and a stacked or late one is not (a wrong buzz is unforgivable; a missed buzz is fine).
     */
    private fun fireCue(cue: LiveSessionEngine.Cue) {
        if (walkJob?.isActive == true) return
        val signal = when (cue) {
            LiveSessionEngine.Cue.PUSH_NUDGE -> LiveSessionHaptics.Signal.PUSH
            LiveSessionEngine.Cue.EASE_OFF -> LiveSessionHaptics.Signal.EASE_OFF
        }
        when (cue) {
            LiveSessionEngine.Cue.PUSH_NUDGE -> pushCount += 1
            LiveSessionEngine.Cue.EASE_OFF -> easeCount += 1
        }
        walkJob = scope.launch {
            for (pulse in LiveSessionHaptics.pulses(signal)) {
                buzz(if (pulse.isLong) 2 else 1)
                delay((pulse.durationMs + pulse.gapMs).toLong())
            }
        }
    }

    private fun publish(out: LiveSessionEngine.Output? = _snapshot.value.output) {
        val until = endTs ?: lastTickTs
        _snapshot.value = Snapshot(
            output = out,
            elapsedSec = (until - startTs).coerceAtLeast(0L).toInt(),
            pushCount = pushCount,
            easeCount = easeCount,
            belowSec = belowSec,
            aboveSec = aboveSec,
            ended = ended,
            endedAutomatically = endedAutomatically,
        )
    }

    private fun openRow() = LiveSessionRow(
        deviceId = deviceId, startTs = startTs, endTs = null,
        chargeAtStart = config.charge,
        floorBpm = band.floorBpm, ceilingBpm = band.ceilingBpm,
        inBandSec = 0.0, belowSec = 0.0, aboveSec = 0.0,
        pushCount = 0, easeCount = 0, hrSource = hrSource,
    )

    private fun closedRow() = LiveSessionRow(
        deviceId = deviceId, startTs = startTs, endTs = endTs,
        chargeAtStart = config.charge,
        floorBpm = band.floorBpm, ceilingBpm = band.ceilingBpm,
        inBandSec = _snapshot.value.output?.inBandSeconds ?: 0.0,
        belowSec = belowSec, aboveSec = aboveSec,
        pushCount = pushCount, easeCount = easeCount, hrSource = hrSource,
    )

    companion object {
        /** 10 minutes of continuous STALE and the guardian bows out (nothing honest left to guard). */
        const val AUTO_END_AFTER_STALE_SEC = 600

        // The single in-flight (or just-ended, awaiting its summary "Done") session, process-visible so
        // Today's entry card and a re-opened dialog find the SAME session after a dismissal — mirroring
        // how the active manual workout survives navigation in the ViewModel.
        private val _active = MutableStateFlow<LiveSessionRunner?>(null)
        val active: StateFlow<LiveSessionRunner?> = _active.asStateFlow()

        /** Install [runner] as the active session and start it. No-op replace-guard: an existing live
         *  session is never silently displaced (the UI only begins one when [active] is null). */
        fun begin(runner: LiveSessionRunner): LiveSessionRunner {
            val current = _active.value
            if (current != null && !current.ended) return current
            _active.value = runner
            runner.start()
            return runner
        }

        /** Drop [runner] from [active] (summary dismissed). Only clears if it is still the active one. */
        fun clear(runner: LiveSessionRunner) {
            _active.compareAndSet(runner, null)
        }
    }
}

// MARK: - LiveSessionPrefs — the `live_sessions_beta` feature flag (Settings toggle, default ON)

/** Gate for the Today entry + the Settings row. BETA-labelled at every surface; flag default ON. */
object LiveSessionPrefs {
    const val KEY_ENABLED = "live_sessions_beta"

    fun enabled(context: Context): Boolean =
        NoopPrefs.of(context).getBoolean(KEY_ENABLED, true)

    fun setEnabled(context: Context, enabled: Boolean) {
        NoopPrefs.of(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }
}

// MARK: - Pure summary helpers (verdict + streak), Context-free so they are JVM-testable

/**
 * One-line plain-English verdict for the summary, from the three accrued buckets. Honest tiers: under a
 * scoreable minute it refuses to judge; ~70%+ in-band is a clean match; then the dominant miss names
 * itself. Never a number dressed up as praise.
 */
internal fun liveSessionVerdict(inBandSec: Double, belowSec: Double, aboveSec: Double): String {
    val total = inBandSec + belowSec + aboveSec
    if (total < 60.0) return "Too short to judge."
    val share = inBandSec / total
    return when {
        share >= 0.70 -> "On track. You matched what today could pay for."
        share >= 0.45 -> "Mixed. In the band about half the time."
        belowSec >= aboveSec -> "Easy day. You sat under the band most of the way."
        else -> "Hot. You ran above today's ceiling most of the way."
    }
}

/**
 * Consecutive-day session streak ending [today], from the (local) days of recent completed sessions.
 * Multiple sessions on one day count once; a missed day breaks the run. Returns 0 when there is no
 * session today (the summary always follows a session, so in practice ≥ 1).
 */
internal fun liveSessionStreakDays(sessionDays: List<LocalDate>, today: LocalDate): Int {
    val days = sessionDays.distinct().sortedDescending()
    var streak = 0
    var cursor = today
    for (d in days) {
        if (d.isAfter(cursor)) continue        // clock skew / future rows: ignore, never crash the count
        if (d != cursor) break                 // gap — the streak ends here
        streak += 1
        cursor = cursor.minusDays(1)
    }
    return streak
}
