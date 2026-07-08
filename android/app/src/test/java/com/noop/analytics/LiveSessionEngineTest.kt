package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [LiveSessionEngine] — the "silent guardian" coach. Fixtures are IDENTICAL to
 * LiveSessionEngineTests.swift so the two engines prove byte-identical behaviour (the cross-platform
 * parity contract). Design contract: docs/superpowers/specs/2026-07-04-live-sessions-design.md.
 */
class LiveSessionEngineTest {

    private val rhr = 55.0
    private val hrMax = 190.0 // reserve = 135

    private fun cfg(charge: Double?) = LiveSessionEngine.Config(rhr, hrMax, charge)

    /** Feed a constant bpm at 1 Hz for [seconds] updates starting at [fromTs]; collect every Output. */
    private fun feed(e: LiveSessionEngine, bpm: Int?, fromTs: Int, seconds: Int): List<LiveSessionEngine.Output> =
        (0 until seconds).map { e.update(fromTs + it, bpm) }

    // ── Band curve (golden vectors) ──

    @Test fun band_scales_ceiling_with_charge() {
        val low = LiveSessionEngine.band(cfg(10.0))
        assertEquals(0.622, low.ceilingPctHRR, 0.001)
        assertEquals(0.472, low.floorPctHRR, 0.001)

        val mid = LiveSessionEngine.band(cfg(41.0))
        assertEquals(0.6902, mid.ceilingPctHRR, 0.001)
        assertEquals(0.5402, mid.floorPctHRR, 0.001)
        assertEquals(148.18, mid.ceilingBpm, 0.1)
        assertEquals(127.93, mid.floorBpm, 0.1)

        val high = LiveSessionEngine.band(cfg(90.0))
        assertEquals(0.798, high.ceilingPctHRR, 0.001)
        assertEquals(0.648, high.floorPctHRR, 0.001)

        assertTrue(high.ceilingBpm > mid.ceilingBpm)
        assertTrue(mid.ceilingBpm > low.ceilingBpm)
    }

    @Test fun band_unknown_charge_is_conservative_midpoint() {
        val b = LiveSessionEngine.band(cfg(null))
        assertEquals(0.71, b.ceilingPctHRR, 0.001)
        assertEquals(0.56, b.floorPctHRR, 0.001)
    }

    @Test fun low_charge_floor_stays_at_or_above_minimum() {
        val b = LiveSessionEngine.band(cfg(0.0))
        assertEquals(0.60, b.ceilingPctHRR, 0.0001)
        assertEquals(0.45, b.floorPctHRR, 0.0001)
        assertTrue(b.floorPctHRR >= LiveSessionEngine.minFloorPctHRR)
    }

    // ── Guardian behaviour ──

    @Test fun warmup_never_buzzes_even_when_out_of_band() {
        val e = LiveSessionEngine(cfg(null), 1000)
        val warm = feed(e, 110, 1000, 60)
        assertTrue(warm.all { it.cue == null })
        assertTrue(warm.all { it.status == LiveSessionEngine.Status.WARMUP })
    }

    @Test fun steady_in_band_is_pure_silence_and_accrues_time() {
        val e = LiveSessionEngine(cfg(null), 0)
        val outs = feed(e, 140, 0, 120)
        assertTrue(outs.all { it.cue == null })
        assertTrue(outs.takeLast(30).all { it.position == LiveSessionEngine.Position.IN_BAND })
        assertTrue(outs.last().inBandSeconds > 100)
    }

    @Test fun sustained_too_easy_pushes_once_then_cools_down() {
        val e = LiveSessionEngine(cfg(null), 1000)
        val outs = feed(e, 110, 1000, 90)
        val cueIdx = outs.indices.filter { outs[it].cue != null }
        assertEquals(1, cueIdx.size)
        assertEquals(LiveSessionEngine.Cue.PUSH_NUDGE, outs[cueIdx.first()].cue)
        assertEquals(60, cueIdx.first())
    }

    @Test fun sharp_climb_over_ceiling_eases_off() {
        val e = LiveSessionEngine(cfg(null), 1000)
        feed(e, 140, 1000, 70)
        val hot = feed(e, 178, 1070, 60)
        assertTrue(hot.any { it.cue == LiveSessionEngine.Cue.EASE_OFF })
        assertFalse(hot.any { it.cue == LiveSessionEngine.Cue.PUSH_NUDGE })
    }

    @Test fun slow_drift_over_ceiling_does_not_ease_off() {
        val e = LiveSessionEngine(cfg(null), 1000)
        feed(e, 140, 1000, 70)
        val outs = (0 until 120).map {
            val bpm = 145 + (it * (25.0 / 120.0)).toInt()
            e.update(1070 + it, bpm)
        }
        assertFalse(outs.any { it.cue == LiveSessionEngine.Cue.EASE_OFF })
    }

    @Test fun reentry_into_band_is_silent() {
        val e = LiveSessionEngine(cfg(null), 1000)
        feed(e, 110, 1000, 90)
        val back = feed(e, 140, 1090, 40)
        assertTrue(back.all { it.cue == null })
        assertTrue(back.takeLast(20).all { it.position == LiveSessionEngine.Position.IN_BAND })
    }

    @Test fun impossible_sample_is_rejected() {
        val e = LiveSessionEngine(cfg(null), 0)
        feed(e, 140, 0, 20)
        val out = e.update(20, 250)
        assertFalse(out.sampleArrived)
        assertEquals(140.0, out.smoothedBpm ?: 0.0, 2.0)
    }

    @Test fun stream_dropout_goes_stale_and_pauses_coaching() {
        val e = LiveSessionEngine(cfg(null), 0)
        feed(e, 110, 0, 20)
        val out = e.update(40, null)
        assertEquals(LiveSessionEngine.Status.STALE, out.status)
        assertNull(out.smoothedBpm)
        assertNull(out.cue)
    }
}
