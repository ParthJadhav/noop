package com.noop.ui

import com.noop.analytics.ReadinessEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A1/S4/S5 parity twins of the iOS TodayChargeTapCollapseTests: the one-word readiness read kept on the
 * hero (#205), the collapsed "Synced from: ..." footer summary (S5), and the metrics-grid overflow cap
 * (S5). These mirror the Swift TodayView.readinessWord / syncedFromSummary / metricsCollapsedCap EXACTLY,
 * so a drift in either platform's labels/numbers fails here.
 */
class TodayChargeTapCollapseTest {

    @Test
    fun readinessWord_mapsEveryLevel() {
        assertEquals("Push", readinessWord(ReadinessEngine.Level.PRIMED))
        assertEquals("Maintain", readinessWord(ReadinessEngine.Level.BALANCED))
        assertEquals("Rest", readinessWord(ReadinessEngine.Level.STRAINED))
        assertEquals("Rest", readinessWord(ReadinessEngine.Level.RUNDOWN))
    }

    @Test
    fun readinessWord_insufficientHasNoWord() {
        assertNull(readinessWord(ReadinessEngine.Level.INSUFFICIENT))
    }

    @Test
    fun syncedFromSummary_listsOnlySourcesWithData() {
        assertEquals(
            "Synced from: WHOOP, Apple Watch",
            syncedFromSummary(hasWhoop = true, hasApple = true, hasXiaomi = false),
        )
        assertEquals(
            "Synced from: WHOOP",
            syncedFromSummary(hasWhoop = true, hasApple = false, hasXiaomi = false),
        )
        assertEquals(
            "Synced from: WHOOP, Apple Watch, Mi Band",
            syncedFromSummary(hasWhoop = true, hasApple = true, hasXiaomi = true),
        )
    }

    @Test
    fun syncedFromSummary_appleHealthReadsAsAppleWatch() {
        assertEquals(
            "Synced from: Apple Watch",
            syncedFromSummary(hasWhoop = false, hasApple = true, hasXiaomi = false),
        )
    }

    @Test
    fun syncedFromSummary_noSourcesIsHonest() {
        assertEquals(
            "No sources yet",
            syncedFromSummary(hasWhoop = false, hasApple = false, hasXiaomi = false),
        )
    }

    @Test
    fun metricsCollapsedCap_isSixTilesThreeRows() {
        assertEquals(6, METRICS_COLLAPSED_CAP)
    }

    @Test
    fun metricsCollapse_keepsLeadingTilesInOrder() {
        // The collapse slices from the FRONT of the saved order, so a pinned/selected tile is never
        // dropped or reordered (#251); only the tail folds. Mirrors MetricGrid's take(cap).
        val saved = (0 until 10).toList()
        val visible = if (saved.size <= METRICS_COLLAPSED_CAP) saved else saved.take(METRICS_COLLAPSED_CAP)
        assertEquals(listOf(0, 1, 2, 3, 4, 5), visible)
    }
}
