package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #977 (display half) — the freshness-gated Rest resolution that keeps the Today Rest ring HONEST for a
 * live 5.0 whose sleep never scores (no overnight gravity ⇒ no `sleep_performance` point ever written).
 * The display used to resolve Rest as "today's value, else the LATEST point in the whole series", which
 * pinned Rest to a weeks-old scored night while Charge (recovery) kept advancing — the frozen "93 since
 * forever" the reporter hit. [freshRestScore] gates the tail-fallback on recency: it still carries last
 * night's Rest before today scores, but once the last scored night is STALE it returns null so the Rest
 * ring falls through to its needs-a-tracked-night state instead of freezing on a stale number. Pure + JVM.
 * Mirrors the iOS `RestFreshnessTests`.
 */
class RestFreshnessTest {

    // A fixed "today" so the recency window is deterministic regardless of the test host's wall clock.
    private val today = "2026-06-19"

    @Test
    fun todaysOwnRow_wins_regardlessOfTail() {
        // Today's own scored Rest is shown even when a (fresher or staler) tail exists.
        assertEquals(
            71.0,
            freshRestScore(todayValue = 71.0, lastDay = "2026-06-18", lastValue = 93.0,
                isTodaySelected = true, today = today),
        )
        // …and even with a stale tail present.
        assertEquals(
            71.0,
            freshRestScore(todayValue = 71.0, lastDay = "2026-06-07", lastValue = 93.0,
                isTodaySelected = true, today = today),
        )
    }

    @Test
    fun freshTail_carries_whenNoTodayRow() {
        // No today row + a FRESH last-scored night (yesterday) → tail-fallback carries last night's Rest.
        // Unchanged (legitimate) morning-carry behaviour.
        assertEquals(
            88.0,
            freshRestScore(todayValue = null, lastDay = "2026-06-18", lastValue = 88.0,
                isTodaySelected = true, today = today),
        )
    }

    @Test
    fun staleTail_doesNotCarry_readsNoData() {
        // No today row + a STALE last-scored night (12 days ago) → NO tail-fallback. This is the frozen-93
        // case: it now reads honestly as no data (null), so the Rest ring shows its needs-a-tracked-night
        // state instead of a frozen number.
        assertNull(
            freshRestScore(todayValue = null, lastDay = "2026-06-07", lastValue = 93.0,
                isTodaySelected = true, today = today),
        )
    }

    @Test
    fun pastDaySelected_neverTailFalls() {
        // A navigated PAST day with no row shows nothing rather than borrowing the newest value.
        assertNull(
            freshRestScore(todayValue = null, lastDay = "2026-06-18", lastValue = 88.0,
                isTodaySelected = false, today = today),
        )
    }

    @Test
    fun noTailAtAll_readsNoData() {
        // Cold start: no today row and no scored night anywhere → no number, no fabrication.
        assertNull(
            freshRestScore(todayValue = null, lastDay = null, lastValue = null,
                isTodaySelected = true, today = today),
        )
    }
}
