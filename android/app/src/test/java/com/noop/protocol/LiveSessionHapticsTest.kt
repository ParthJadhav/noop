package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [LiveSessionHaptics] — the two Live Session wrist signals. Fixtures are IDENTICAL to
 * LiveSessionHapticsTests.swift so the two encoders prove byte-identical pulse lists (parity contract).
 * Design contract: docs/superpowers/specs/2026-07-04-live-sessions-design.md.
 */
class LiveSessionHapticsTest {

    @Test fun push_is_two_light_taps() {
        val pulses = LiveSessionHaptics.pulses(LiveSessionHaptics.Signal.PUSH)
        assertEquals(
            listOf(HapticClock.Pulse(200, 450), HapticClock.Pulse(200, 0)),
            pulses,
        )
        assertTrue(pulses.all { !it.isLong })
    }

    @Test fun easeOff_is_three_heavy_taps() {
        val pulses = LiveSessionHaptics.pulses(LiveSessionHaptics.Signal.EASE_OFF)
        assertEquals(
            listOf(HapticClock.Pulse(550, 450), HapticClock.Pulse(550, 450), HapticClock.Pulse(550, 0)),
            pulses,
        )
        assertTrue(pulses.all { it.isLong })
    }

    @Test fun signals_are_distinguishable_by_count_and_weight() {
        val push = LiveSessionHaptics.pulses(LiveSessionHaptics.Signal.PUSH)
        val ease = LiveSessionHaptics.pulses(LiveSessionHaptics.Signal.EASE_OFF)
        assertEquals(2, push.size)
        assertEquals(3, ease.size)
        assertNotEquals(push.first().isLong, ease.first().isLong)
    }
}
