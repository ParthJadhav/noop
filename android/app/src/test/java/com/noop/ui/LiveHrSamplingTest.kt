package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The live-HR hero's 1 Hz sampling tick (#941, ryanbr). The old buffer appended on VALUE CHANGE, and
 * the smoothed bpm StateFlow conflates duplicates, so a steady heart rate banked zero points and the
 * time-axis chart drew a phantom ramp across the quiet stretch. The clock tick banks the latest value
 * every second through [appendLiveHrSample]; these tests pin the tick's guard + cap contract:
 *  - nothing banked while there's no reading (null stops the buffer, it never flat-lines a dead value),
 *  - the 30..220 physiological range guard (same bounds the on-change append used),
 *  - the rolling cap drops the OLDEST sample, so 180 samples at 1 Hz is a strict ~3 minutes.
 *
 * LIFECYCLE CONTRACT (data-honesty, not unit-testable here since it lives in the Compose effect): the
 * sampling loop in HealthScreen runs inside `lifecycleOwner.lifecycle.repeatOnLifecycle(STARTED)`, so it
 * only ticks while the UI is at least STARTED. Its inputs (bpm/live) are collected with
 * collectAsStateWithLifecycle, which STOPS at ON_STOP; without the gate the loop would keep banking the
 * frozen last value once a second with real timestamps while backgrounded (the BLE foreground service
 * holds the process alive), fabricating a flat trace - and persisting it if the strap dropped meanwhile.
 * The gate suspends banking exactly when the inputs freeze and resumes it when fresh state flows again,
 * matching iOS, whose timer suspends when backgrounded. [appendLiveHrSample] therefore only ever runs
 * against a LIVE (foreground) reading, which is what the guards below assume.
 */
class LiveHrSamplingTest {

    private fun buf(vararg bpm: Int): MutableList<LiveHrSample> =
        bpm.mapIndexed { i, v -> LiveHrSample(timeMs = i * 1000L, bpm = v.toDouble()) }.toMutableList()

    // ── presence + range guard ──────────────────────────────────────────────────

    @Test fun nullReadingBanksNothing() {
        val history = buf(72)
        appendLiveHrSample(history, bpm = null, timeMs = 5_000L)
        assertEquals(1, history.size)
    }

    @Test fun outOfRangeReadingsAreRejected() {
        val history = buf()
        appendLiveHrSample(history, bpm = 29, timeMs = 1_000L)
        appendLiveHrSample(history, bpm = 221, timeMs = 2_000L)
        assertTrue(history.isEmpty())
    }

    @Test fun rangeBoundsAreInclusive() {
        val history = buf()
        appendLiveHrSample(history, bpm = 30, timeMs = 1_000L)
        appendLiveHrSample(history, bpm = 220, timeMs = 2_000L)
        assertEquals(2, history.size)
        assertEquals(30.0, history[0].bpm, 0.0)
        assertEquals(220.0, history[1].bpm, 0.0)
    }

    @Test fun sampleCarriesTheTickTimestamp() {
        val history = buf()
        appendLiveHrSample(history, bpm = 72, timeMs = 123_456L)
        assertEquals(123_456L, history.single().timeMs)
    }

    // ── steady HR keeps banking (the #941 point) ────────────────────────────────

    @Test fun repeatedIdenticalValuesEachBankASample() {
        val history = buf()
        appendLiveHrSample(history, bpm = 65, timeMs = 1_000L)
        appendLiveHrSample(history, bpm = 65, timeMs = 2_000L)
        appendLiveHrSample(history, bpm = 65, timeMs = 3_000L)
        assertEquals(3, history.size)
        assertEquals(listOf(1_000L, 2_000L, 3_000L), history.map { it.timeMs })
    }

    // ── rolling cap ─────────────────────────────────────────────────────────────

    @Test fun capDropsTheOldestSample() {
        val history = buf()
        appendLiveHrSample(history, bpm = 60, timeMs = 0L, cap = 3)
        appendLiveHrSample(history, bpm = 61, timeMs = 1_000L, cap = 3)
        appendLiveHrSample(history, bpm = 62, timeMs = 2_000L, cap = 3)
        appendLiveHrSample(history, bpm = 63, timeMs = 3_000L, cap = 3)
        assertEquals(3, history.size)
        assertEquals(listOf(61.0, 62.0, 63.0), history.map { it.bpm })
    }

    @Test fun defaultCapIsThreeMinutesAtOneHz() {
        assertEquals(180, LIVE_HR_BUFFER_CAP)
        val history = buf()
        repeat(200) { appendLiveHrSample(history, bpm = 70, timeMs = it * 1000L) }
        assertEquals(180, history.size)
        // The oldest 20 ticks fell off the front.
        assertEquals(20_000L, history.first().timeMs)
    }
}
