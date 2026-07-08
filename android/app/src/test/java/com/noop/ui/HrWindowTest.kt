package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the Today HR card's window-narrowing contract (#985's UX reimplemented under the #829 view-only
 * rule): a window NEVER re-queries the DB — it only narrows which of the already-loaded 5-minute buckets
 * render — so the entire behaviour lives in the pure cutoff/filter seam tested here. If someone "improves"
 * this into a re-read (the shape PR #985 originally proposed), these are the tests to argue with first.
 */
class HrWindowTest {

    private val now = 1_760_000_000L

    @Test
    fun today_never_narrows() {
        // TODAY is the unchanged full-day default: every loaded bucket survives, however old.
        assertEquals(Long.MIN_VALUE, HrWindow.TODAY.cutoff(now))
        assertTrue(hrWindowKeeps(0L, HrWindow.TODAY, now))
        assertTrue(hrWindowKeeps(now - 30 * 24 * 3600L, HrWindow.TODAY, now))
    }

    @Test
    fun rolling_cutoffs_anchor_at_now() {
        assertEquals(now - 1 * 3600L, HrWindow.H1.cutoff(now))
        assertEquals(now - 3 * 3600L, HrWindow.H3.cutoff(now))
        assertEquals(now - 6 * 3600L, HrWindow.H6.cutoff(now))
        assertEquals(now - 12 * 3600L, HrWindow.H12.cutoff(now))
        assertEquals(now - 24 * 3600L, HrWindow.H24.cutoff(now))
    }

    @Test
    fun narrower_window_keeps_a_subset_of_a_wider_one() {
        // A loaded day of 5-minute buckets counting back from now.
        val buckets = (0..288).map { now - it * 300L }
        val narrowToWide = listOf(HrWindow.H1, HrWindow.H3, HrWindow.H6, HrWindow.H12, HrWindow.H24, HrWindow.TODAY)
        val kept = narrowToWide.map { w -> buckets.filter { hrWindowKeeps(it, w, now) }.toSet() }
        kept.zipWithNext().forEach { (narrow, wide) ->
            assertTrue("narrower window kept a bucket its wider neighbour dropped", wide.containsAll(narrow))
        }
    }

    @Test
    fun the_newest_bucket_survives_every_window() {
        // The filter only drops OLD buckets, so the card's trailing "latest bpm" read-out is
        // window-invariant — switching windows never changes the headline number.
        val newest = now - 10L
        HrWindow.entries.forEach { w ->
            assertTrue("$w dropped the newest bucket", hrWindowKeeps(newest, w, now))
        }
    }

    @Test
    fun a_stale_bucket_outside_the_window_is_dropped_not_reanchored() {
        // Strap hasn't offloaded for two hours: the 1h window honestly keeps nothing from back then
        // (the card shows its window-aware empty state with the pills still up), while 3h keeps it.
        val stale = now - 2 * 3600L
        assertFalse(hrWindowKeeps(stale, HrWindow.H1, now))
        assertTrue(hrWindowKeeps(stale, HrWindow.H3, now))
    }

    @Test
    fun pill_order_is_today_then_widest_to_narrowest() {
        // Declaration order IS the pill order, and TODAY must stay ordinal 0: the rememberSaveable
        // default is the ordinal, so reordering the enum would silently change the default window.
        assertEquals(listOf("Today", "24h", "12h", "6h", "3h", "1h"), HrWindow.entries.map { it.label })
        assertEquals(0, HrWindow.TODAY.ordinal)
    }
}
