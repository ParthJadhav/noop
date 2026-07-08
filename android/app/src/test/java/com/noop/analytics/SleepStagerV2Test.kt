package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.roundToInt

/**
 * Basic coverage for the OPT-IN experimental stager [SleepStagerV2] (V7 Pillar 3b, reimplemented from
 * contributor PR #600), the Android twin of SleepStagerV2Tests.swift. Asserts the drop-in CONTRACT — same
 * [SleepStager.stageSession] signature + return shape, segments that tile [start, end] with canonical stage
 * labels — and that the [SleepStageHealer] V1/V2 switch actually routes to V2 (and defaults to V1, byte for
 * byte). NOT a fidelity claim against any reference (the recipe's own validation is n=1).
 */
class SleepStagerV2Test {

    private val dev = "test"

    /** 2025-06-10 00:00:00 UTC — fixed midnight, as in the other stager tests. */
    private val refMidnight = 1_749_513_600L

    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    private fun sleepHR(start: Long, durationS: Int, base: Int = 52): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = base + ((it / 60) % 3).toInt()) }

    private fun regularRR(start: Long, durationS: Int): List<RrInterval> =
        (0 until durationS).map { i ->
            val rsa = (40.0 * sin(2.0 * PI * i / 4.0)).roundToInt()  // ~0.25 Hz breathing
            RrInterval(deviceId = dev, ts = start + i, rrMs = 1000 + rsa)
        }

    // ── drop-in contract ─────────────────────────────────────────────────────────────────────────────

    @Test
    fun stagesTileTheWholeSpanContiguously() {
        val start = refMidnight + 3_600L
        val dur = 90 * 60
        val end = start + dur
        val segs = SleepStagerV2.stageSession(
            start = start, end = end,
            grav = stillGravity(start, dur), hr = sleepHR(start, dur), rr = regularRR(start, dur),
            resp = emptyList())

        assertFalse("a covered window must produce at least one segment", segs.isEmpty())
        assertEquals("first segment starts at `start`", start, segs.first().start)
        assertEquals("last segment ends at `end`", end, segs.last().end)
        for (i in 1 until segs.size) {
            assertEquals("segments tile with no gap/overlap", segs[i - 1].end, segs[i].start)
            assertTrue("each segment is non-empty", segs[i].end > segs[i].start)
        }
    }

    @Test
    fun onlyCanonicalStageLabels() {
        val start = refMidnight + 3_600L
        val dur = 80 * 60
        val segs = SleepStagerV2.stageSession(
            start = start, end = start + dur,
            grav = stillGravity(start, dur), hr = sleepHR(start, dur), rr = regularRR(start, dur),
            resp = emptyList())
        val allowed = setOf("wake", "light", "deep", "rem")
        for (s in segs) assertTrue("unexpected stage label ${s.stage}", s.stage in allowed)
    }

    @Test
    fun degenerateInputFallsBackToSingleLightBlock() {
        val start = refMidnight
        val end = start + 3_600L
        val segs = SleepStagerV2.stageSession(
            start = start, end = end,
            grav = listOf(GravitySample(deviceId = dev, ts = start, x = 0.0, y = 0.0, z = 1.0)),
            hr = emptyList(), rr = emptyList(), resp = emptyList())
        assertEquals(1, segs.size)
        assertEquals("light", segs.first().stage)
        assertEquals(start, segs.first().start)
        assertEquals(end, segs.first().end)
    }

    // ── the SleepStageHealer V1/V2 switch ──────────────────────────────────────────────────────────────

    /** The opt-in flag routes the heal's re-stage to V2; default (false) stays on V1, byte-identical. */
    @Test
    fun healerSwitchSelectsV2WhenFlagOn() {
        val start = refMidnight + 3_600L
        val dur = 6 * 60 * 60
        val end = start + dur - 1
        val grav = stillGravity(start, dur)
        val hr = sleepHR(start, dur)
        val rr = regularRR(start, dur)

        val v1 = SleepStageHealer.restageFromSamples(start, end, grav, hr, rr, emptyList())
        val v1Default = SleepStageHealer.restageFromSamples(
            start, end, grav, hr, rr, emptyList(), useExperimentalSleepV2 = false)
        val v2 = SleepStageHealer.restageFromSamples(
            start, end, grav, hr, rr, emptyList(), useExperimentalSleepV2 = true)

        assertNotNull("dense raw must stage on both paths", v1)
        assertNotNull(v2)
        assertEquals("default flag is V1 (byte-identical to the no-flag call)", v1, v1Default)
        assertTrue("V1 output is a segment array", v1!!.trimStart().startsWith("["))
        assertTrue("V2 output is a segment array", v2!!.trimStart().startsWith("["))
    }

    // ── #690: the V2 flag drives the NORMAL detected-night staging path ─────────────────────────────────

    /**
     * #690 (v7 regression): the "Experimental sleep staging (V2)" toggle must affect a NORMAL detected
     * night — not only the userEdited self-heal restage. With the flag ON, [SleepStager.detectSleep]
     * stages the accepted window with V2 (deep + REM present); with the flag OFF it returns the EXACT V1
     * result, so the byte-identical default (and the frozen-golden tests) is preserved. Android twin of
     * SleepStagerV2Tests.testDetectSleepThreadsV2FlagIntoNormalNight.
     */
    @Test
    fun detectSleepThreadsV2FlagIntoNormalNight() {
        // A 3 h still overnight window (anchored at 01:00 UTC → center ~02:30, clear of the daytime guard
        // band at the default tzOffset=0) with sleep-band HR + a regular R-R stream.
        val start = refMidnight + 3_600L
        val dur = 3 * 60 * 60
        val grav = stillGravity(start, dur)
        val hr = sleepHR(start, dur)
        val rr = regularRR(start, dur)

        // Flag OFF (the default) — V1 path.
        val v1Sessions = SleepStager.detectSleep(hr = hr, rr = rr, gravity = grav)
        assertEquals("the still night must be detected", 1, v1Sessions.size)
        val v1 = v1Sessions[0]
        // The detected window's stages MUST equal a direct V1 stageSession over the same span (proof the
        // default path is byte-identical and untouched by the new parameter).
        val v1Direct = SleepStager.stageSession(
            start = v1.start, end = v1.end, grav = grav, hr = hr, rr = rr, resp = emptyList())
        assertEquals("flag OFF must reproduce the exact V1 hypnogram", v1Direct, v1.stages)

        // Flag ON — the SAME detected window must now be staged by V2.
        val v2Sessions = SleepStager.detectSleep(hr = hr, rr = rr, gravity = grav, useSleepStagerV2 = true)
        assertEquals("detection is unchanged by the staging flag", 1, v2Sessions.size)
        val v2 = v2Sessions[0]
        assertEquals(v1.start, v2.start)
        assertEquals(v1.end, v2.end)
        // The hypnogram is V2's: it matches a direct V2 stageSession over the accepted span, and (proof the
        // flag actually flipped the engine) it expresses both deep and REM.
        val v2Direct = SleepStagerV2.stageSession(
            start = v2.start, end = v2.end, grav = grav, hr = hr, rr = rr, resp = emptyList())
        assertEquals("flag ON must produce the V2 hypnogram", v2Direct, v2.stages)
        val v2Stages = v2.stages.map { it.stage }.toSet()
        assertTrue("V2 night should express deep", "deep" in v2Stages)
        assertTrue("V2 night should express REM", "rem" in v2Stages)
    }
}
