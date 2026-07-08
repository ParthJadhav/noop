package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure capped-exponential reconnect schedule (#48). Mirrors the iOS BLEManager backoff
 * `min(60, 3 * 2^(n-1))` (BLEManager.swift didFailToConnect): 3, 6, 12, 24, 48, 60s then held.
 * No android.bluetooth — [ReconnectBackoff.nextDelayMs] is a pure function of the attempt number.
 */
class ReconnectBackoffTest {

    @Test
    fun firstSixAttemptsMatchTheCappedExponentialSchedule() {
        // 1-based attempts: 3 → 6 → 12 → 24 → 48 → 60 (cap reached at attempt 6).
        assertEquals(3_000L, ReconnectBackoff.nextDelayMs(1))
        assertEquals(6_000L, ReconnectBackoff.nextDelayMs(2))
        assertEquals(12_000L, ReconnectBackoff.nextDelayMs(3))
        assertEquals(24_000L, ReconnectBackoff.nextDelayMs(4))
        assertEquals(48_000L, ReconnectBackoff.nextDelayMs(5))
        assertEquals(60_000L, ReconnectBackoff.nextDelayMs(6))
    }

    @Test
    fun attemptFiveIsTheLastValueBelowTheCeiling() {
        // 48s (= 3000 shl 4) is the largest shift we ever perform; everything beyond short-circuits.
        assertEquals(48_000L, ReconnectBackoff.nextDelayMs(5))
        assertTrue(ReconnectBackoff.nextDelayMs(5) < ReconnectBackoff.MAX_DELAY_MS)
    }

    @Test
    fun delayNeverExceedsTheCeilingForLargeAttempts() {
        // The schedule holds flat at 60s once past the knee — and never overflows for an absurd
        // attempt count (the guard short-circuits before `3000 shl n` could blow up a Long).
        assertEquals(60_000L, ReconnectBackoff.nextDelayMs(7))
        assertEquals(60_000L, ReconnectBackoff.nextDelayMs(20))
        assertEquals(60_000L, ReconnectBackoff.nextDelayMs(64))
        assertEquals(60_000L, ReconnectBackoff.nextDelayMs(Int.MAX_VALUE))
    }

    @Test
    fun zeroAndNegativeAttemptsCoerceToTheBaseDelay() {
        // An uninitialised / underflowed counter must never produce a sub-base or negative wait.
        assertEquals(ReconnectBackoff.BASE_DELAY_MS, ReconnectBackoff.nextDelayMs(0))
        assertEquals(ReconnectBackoff.BASE_DELAY_MS, ReconnectBackoff.nextDelayMs(-1))
        assertEquals(ReconnectBackoff.BASE_DELAY_MS, ReconnectBackoff.nextDelayMs(Int.MIN_VALUE))
    }

    @Test
    fun everyDelayIsAtLeastOneAndWithinBounds() {
        // Defensive: no attempt value can yield a non-positive delay or one above the ceiling.
        for (n in -5..70) {
            val d = ReconnectBackoff.nextDelayMs(n)
            assertTrue("attempt $n gave $d (< 1)", d >= 1L)
            assertTrue("attempt $n gave $d (> cap)", d <= ReconnectBackoff.MAX_DELAY_MS)
        }
    }

    @Test
    fun scheduleMatchesTheClosedFormMinSixtyThreeTimesTwoToTheN() {
        // Independent cross-check of the SAME curve the Oura auto-reconnect (#912) and the iOS
        // BLEManager both ride: min(60, 3 * 2^(n-1)) seconds, computed here from scratch (not via the
        // shift path) so a regression in the production `shl` implementation is caught by a second formula.
        for (n in 1..12) {
            val closedFormSeconds = minOf(60.0, 3.0 * Math.pow(2.0, (n - 1).toDouble()))
            val expectedMs = (closedFormSeconds * 1000.0).toLong()
            assertEquals("attempt $n", expectedMs, ReconnectBackoff.nextDelayMs(n))
        }
    }
}
