package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the equivalence the #970 owner-probe short-circuit relies on (IntelligenceEngine.resolveDayOwner,
 * Swift-parity port of afe15f17). The guard skips the per-day LIMIT-1 HR probe when the registry holds
 * exactly ONE live candidate and it IS the fallback id, on the claim that the probed outcome is a
 * foregone conclusion: whichever way the probe lands, [DayOwnerResolver.resolve] returns the fallback id.
 * These tests pin both arms of that claim against the pure resolver — and the one case the guard must
 * NOT cover (a lone candidate under a DIFFERENT id), where the probe outcome genuinely matters, which is
 * why the guard is gated on `== importedDeviceId` rather than just `size == 1`.
 */
class DayOwnerSingleCandidateShortCircuitTest {

    private val day = "2026-07-01"

    @Test
    fun soleFallbackCandidateWithDataResolvesToItself() {
        // Probe would find data → the resolver returns the candidate's own id == the fallback.
        val sole = DayOwnerResolver.Candidate("my-whoop", priority = 0, hasData = true)
        assertEquals("my-whoop", DayOwnerResolver.resolve(day, lockedOwner = null, candidates = listOf(sole)))
    }

    @Test
    fun soleFallbackCandidateWithoutDataFallsBackToTheSameId() {
        // Probe would find nothing → the resolver returns null and the caller applies the fallback —
        // the SAME id again. Together with the test above: the probe cannot change the answer, so
        // skipping it is byte-identical.
        val sole = DayOwnerResolver.Candidate("my-whoop", priority = 0, hasData = false)
        assertNull(DayOwnerResolver.resolve(day, lockedOwner = null, candidates = listOf(sole)))
    }

    @Test
    fun soleCandidateUnderADifferentIdIsNotAForegoneConclusion() {
        // A lone import paired under its own id: WITH data it owns the day (its id, not the fallback);
        // WITHOUT data the caller falls back to "my-whoop". Two different answers → the probe is load-
        // bearing, so the #970 guard must not (and does not) short-circuit this shape.
        val lone = DayOwnerResolver.Candidate("oura-import", priority = 2, hasData = true)
        assertEquals("oura-import", DayOwnerResolver.resolve(day, lockedOwner = null, candidates = listOf(lone)))
        val loneNoData = DayOwnerResolver.Candidate("oura-import", priority = 2, hasData = false)
        assertNull(DayOwnerResolver.resolve(day, lockedOwner = null, candidates = listOf(loneNoData)))
    }
}
