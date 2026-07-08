package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Golden vectors for the #1004 uprightness attenuation — the pure math that makes the liquid settle
 * LEVEL when the phone is near-flat or the user is lying down, instead of pinning sideways off a
 * meaningless roll reading. MIRRORED bit-for-bit on iOS (LiquidCore.swift `LiquidMotion.uprightAttenuation`,
 * same 0.25→0.65 smoothstep ramp); iOS has no headless XCTest lane for app-target code, so this JVM test
 * is the single cross-platform lock — change one side and these vectors are how the drift gets caught.
 */
class LiquidUprightTest {

    private val eps = 1e-12

    @Test
    fun flat_and_below_the_ramp_is_fully_level() {
        // Flat on a table / lying sideways (uprightness ~0), upside down (-1), and everything up to the
        // ramp foot at 0.25: zero tilt response — the surface sits level.
        assertEquals(0.0, liquidUprightAttenuation(-1.0), eps)
        assertEquals(0.0, liquidUprightAttenuation(0.0), eps)
        assertEquals(0.0, liquidUprightAttenuation(0.25), eps)
    }

    @Test
    fun upright_keeps_the_full_response() {
        // Normal handheld posture (phone reclined toward the face) already clears the ramp head at 0.65,
        // so everyday use keeps the full slosh — the fix only bites toward flat.
        assertEquals(1.0, liquidUprightAttenuation(0.65), eps)
        assertEquals(1.0, liquidUprightAttenuation(1.0), eps)
    }

    @Test
    fun smoothstep_interior_vectors() {
        // t = (u - 0.25) / 0.40, smoothstep t²(3-2t): the shared golden points.
        assertEquals(0.15625, liquidUprightAttenuation(0.35), eps)  // t = 0.25
        assertEquals(0.5, liquidUprightAttenuation(0.45), eps)      // t = 0.50 (ramp midpoint)
        assertEquals(0.84375, liquidUprightAttenuation(0.55), eps)  // t = 0.75
    }

    @Test
    fun monotonic_across_the_ramp() {
        // No hard snap and no reversal anywhere: more upright never means LESS tilt response.
        var prev = liquidUprightAttenuation(-1.0)
        var u = -1.0
        while (u <= 1.0) {
            val v = liquidUprightAttenuation(u)
            assertTrue("attenuation reversed at uprightness $u", v >= prev)
            prev = v
            u += 0.01
        }
    }
}
