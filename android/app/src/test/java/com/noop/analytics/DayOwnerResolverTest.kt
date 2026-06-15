package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure day-owner resolution contract — mirrors the Swift DayOwnerResolverTests in
 * Packages/StrandAnalytics. No Room/Android: [DayOwnerResolver] is a pure function.
 */
class DayOwnerResolverTest {

    @Test
    fun activeStrapWinsSharedDay() {
        // Both the active strap (priority 0) and an import (priority 2) have data → the strap owns it.
        val candidates = listOf(
            DayOwnerResolver.Candidate("my-whoop", priority = 0, hasData = true),
            DayOwnerResolver.Candidate("oura", priority = 2, hasData = true),
        )
        assertEquals(
            "my-whoop",
            DayOwnerResolver.resolve("2026-06-15", lockedOwner = null, candidates = candidates),
        )
    }

    @Test
    fun importFillsGap() {
        // The strap has no data for the day → the import (the only candidate with data) owns it.
        val candidates = listOf(
            DayOwnerResolver.Candidate("my-whoop", priority = 0, hasData = false),
            DayOwnerResolver.Candidate("oura", priority = 2, hasData = true),
        )
        assertEquals(
            "oura",
            DayOwnerResolver.resolve("2026-06-15", lockedOwner = null, candidates = candidates),
        )
    }

    @Test
    fun lockedWins() {
        // A locked owner overrides priority/data — even though only the import has data, the locked
        // "my-whoop" wins.
        val candidates = listOf(
            DayOwnerResolver.Candidate("my-whoop", priority = 0, hasData = false),
            DayOwnerResolver.Candidate("oura", priority = 2, hasData = true),
        )
        assertEquals(
            "my-whoop",
            DayOwnerResolver.resolve("2026-06-15", lockedOwner = "my-whoop", candidates = candidates),
        )
    }

    @Test
    fun noDataNull() {
        // No candidate has data and there is no lock → no owner.
        val candidates = listOf(
            DayOwnerResolver.Candidate("my-whoop", priority = 0, hasData = false),
        )
        assertNull(DayOwnerResolver.resolve("2026-06-15", lockedOwner = null, candidates = candidates))
    }
}
