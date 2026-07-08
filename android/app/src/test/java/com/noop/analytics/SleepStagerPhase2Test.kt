package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Sleep-engine Phase 2 (#561/H4/H7/H8/H9) — the SleepStager-side cases.
 *
 * Faithful Kotlin mirror of the Phase-2 cases in SleepStagerTests.swift:
 *   - H4 physiological in-bed span cap (an >16 h bad-clock block is dropped);
 *   - H7 morning-stillness nap suppression (the pure guard + the band-state CONSUME rescue);
 *   - H8 per-epoch motion (sessionEpochMotion grids to the stage epochs).
 * Same reference midnight, thresholds, and scenarios as Swift.
 */
class SleepStagerPhase2Test {

    private val dev = "test"

    /** 2025-06-10 00:00:00 UTC — an arbitrary fixed midnight (ref % 86400 == 0). */
    private val refMidnight = 1_749_513_600L

    /** Unix start at `hourUTC:00:00` on the reference day. tzOffset 0 → local hour == UTC hour. */
    private fun startAtHour(hourUTC: Int): Long = refMidnight + hourUTC * 3_600L

    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    private fun hrStream(start: Long, durationS: Int, bpm: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    // ── H4 physiological in-bed span cap (#547/#531/#509 tail) ───────────────────────────────────

    @Test
    fun detectSleepClampsOverlongBadClockBlock() {
        // 18 h still "night" > 16 h cap → dropped, so it can never report a 12 h+ sleep.
        val start = startAtHour(22)
        val dur = 18 * 60 * 60
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)
        assertTrue("an 18 h still block is a bad-clock artefact and is dropped by the span cap",
            SleepStager.detectSleep(hr = hr, gravity = grav).isEmpty())
    }

    @Test
    fun detectSleepKeepsLongButPlausibleNight() {
        // 15 h ≤ cap → kept (the cap only drops the clock-artefact range, never a real lie-in).
        val start = startAtHour(21)
        val dur = 15 * 60 * 60
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)
        assertEquals("a 15 h night is below the cap and survives", 1,
            SleepStager.detectSleep(hr = hr, gravity = grav).size)
    }

    // ── H7 morning-stillness nap suppression (#531) — pure guard ─────────────────────────────────

    private fun daytimePeriod(startHour: Int, durMin: Int): SleepStager.Period {
        val s = startAtHour(startHour)
        return SleepStager.Period(stage = "sleep", start = s, end = s + durMin * 60L)
    }

    @Test
    fun morningStillnessRejectedNearOvernightWake() {
        // Clears the ordinary daytime guard (74 ≤ 0.95×80=76) but NOT the re-onset bar (74 > 0.90×80=72),
        // right after an 08:00 overnight wake → rejected as morning residual stillness.
        val p = daytimePeriod(9, 120)
        val wakeEnd = startAtHour(8)
        assertFalse("a still block right after the overnight wake with no clear re-onset dip is rejected",
            SleepStager.passesMorningStillnessGuard(p, 74, 80.0, wakeEnd))
    }

    @Test
    fun morningStillnessKeptOnStrongReonsetDip() {
        // A clear cardiac dip (70 ≤ 0.90×78=70.2) → a genuine second sleep is kept.
        val p = daytimePeriod(9, 120)
        val wakeEnd = startAtHour(8)
        assertTrue("a clear re-onset HR dip keeps a genuine morning second sleep",
            SleepStager.passesMorningStillnessGuard(p, 70, 78.0, wakeEnd))
    }

    @Test
    fun morningStillnessGuardNoOpOutsideWindow() {
        // No overnight wake nearby (morningWakeEnd null) → only the ordinary daytime guard applies.
        val p = daytimePeriod(14, 120)
        assertTrue("outside the morning window the guard is the ordinary daytime bar",
            SleepStager.passesMorningStillnessGuard(p, 70, 80.0, null))
    }

    @Test
    fun morningStillnessRescuedByBandSleepState() {
        // The strap's OWN banked band sleep_state reads predominantly "asleep" (2) → CONSUME path KEEPS it
        // even on a borderline HR dip that would otherwise be rejected.
        val p = daytimePeriod(9, 120)
        val wakeEnd = startAtHour(8)
        val band = (0 until 100).map { (p.start + it * 60L) to (if (it < 80) 2 else 1) }
        assertTrue("the strap's own 'asleep' band rescues a borderline-HR morning re-onset",
            SleepStager.passesMorningStillnessGuard(p, 74, 80.0, wakeEnd, band))
        assertFalse("without the band anchor the same borderline block is rejected",
            SleepStager.passesMorningStillnessGuard(p, 74, 80.0, wakeEnd))
    }

    @Test
    fun bandStateConfirmsAsleepFractionGate() {
        val p = daytimePeriod(9, 60)
        val half = (0 until 100).map { (p.start + it * 30L) to (if (it < 50) 2 else 0) }  // 50% < 0.6
        assertFalse(SleepStager.bandStateConfirmsAsleep(p, half))
        assertFalse("empty band → never confirmed (no fabricated reading)",
            SleepStager.bandStateConfirmsAsleep(p, emptyList()))
    }

    // ── H8 per-epoch motion (persisted beside stagesJSON) ────────────────────────────────────────

    @Test
    fun sessionEpochMotionGridsToStageEpochs() {
        // 90-min still night → 180 thirty-second epochs of near-zero motion.
        val start = startAtHour(2)
        val dur = 90 * 60
        val grav = stillGravity(start, dur)
        val motion = SleepStager.sessionEpochMotion(start, start + dur, grav)
        assertEquals("one motion value per 30 s epoch", 180, motion.size)
        assertTrue("motion magnitudes are non-negative |Δgravity| sums", motion.all { it >= 0.0 })
        assertEquals("a perfectly still stream has ~zero motion", 0.0, motion.sum(), 1e-6)
    }

    @Test
    fun sessionEpochMotionEmptyWhenNoGravity() {
        assertTrue("too little gravity to grid → [] so the caller persists NULL",
            SleepStager.sessionEpochMotion(0L, 1800L, emptyList()).isEmpty())
    }

    // ── #175 per-session band sleep_state gridding (persisted beside stagesJSON) ──────────────────

    @Test
    fun sessionEpochSleepStateGridsOnePerEpoch() {
        // 90-min session at 1 sample/30 s all "asleep" (2) → 180 epochs, all 2 (matches sessionEpochMotion).
        val start = 1_000_000L
        val dur = 90 * 60
        val band = (0 until dur / 30).map { (start + it * 30L) to 2 }
        val states = SleepStager.sessionEpochSleepState(start, start + dur, band)
        assertEquals("one band-state value per 30 s epoch", 180, states.size)
        assertTrue("an all-asleep band grids to all-asleep epochs", states.all { it == 2 })
    }

    @Test
    fun sessionEpochSleepStateCarriesForwardAndVerbatim() {
        // A sparse band that flips wake(0)→asleep(2)→up(3): last-in-epoch wins; empty epochs carry forward;
        // state 0 is a REAL wake reading, carried verbatim.
        val band = listOf(0L to 0, 75L to 2, 160L to 3)   // 6 epochs over [0, 180)
        val states = SleepStager.sessionEpochSleepState(0L, 180L, band)
        assertEquals(listOf(0, 0, 2, 2, 2, 3), states)
    }

    @Test
    fun sessionEpochSleepStateEmptyWhenNoBandSamples() {
        // No band samples → [] so the caller persists NULL (a WHOOP 4.0 / unbanded window), never fabricated.
        assertTrue(SleepStager.sessionEpochSleepState(0L, 1800L, emptyList()).isEmpty())
        assertTrue("samples outside the window are ignored",
            SleepStager.sessionEpochSleepState(0L, 1800L, listOf(9_000L to 2)).isEmpty())
    }

    @Test
    fun sessionGridFeedsTheReonsetGuardEndToEnd() {
        // The FULL #175 consume chain: an "asleep"-banded morning block grids to a per-session state array
        // (what IntelligenceEngine persists), which — expanded back to (startTs + i·30, state) samples exactly
        // as bandSleepStateSamples does — makes the H7 re-onset CONFIRM guard KEEP a borderline-HR block it
        // would otherwise reject. Never overrides the derived stage, only confirms. (120 min clears the 90-min bar.)
        val p = daytimePeriod(9, 120)
        val wakeEnd = startAtHour(8)
        val band = (0 until 240).map { (p.start + it * 30L) to 2 }
        val states = SleepStager.sessionEpochSleepState(p.start, p.end, band)
        assertEquals(240, states.size)
        assertTrue(states.all { it == 2 })
        val reconstructed = states.mapIndexed { i, st -> (p.start + i * 30L) to st }
        assertTrue("the persisted+re-expanded band grid drives the H7 confirm end to end",
            SleepStager.passesMorningStillnessGuard(p, 74, 80.0, wakeEnd, reconstructed))
    }
}
