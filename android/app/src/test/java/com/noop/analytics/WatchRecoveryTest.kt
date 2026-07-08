package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin twin of the macOS WatchRecoveryTests: the honesty-critical recovery-from-daily-aggregate engine
 * behind source-only Charge (Apple Watch / Health Connect / Oura-Fitbit-Garmin import, #823). A daily
 * source gives a sparse HRV + resting HR rather than the strap's dense R-R stream, so these fixtures pin the
 * BEHAVIOUR (at-baseline ~ mid, high-HRV / low-RHR -> high, thin history / missing today -> null +
 * calibrating) regardless of the exact logistic constants, which are inherited unchanged from RecoveryScorer
 * so source-only recovery and strap recovery sit on the same scale.
 */
class WatchRecoveryTest {

    @Test
    fun atBaselineGivesMidRecoverySolid() {
        val hist = List(14) { 45.0 }
        val rhrHist = List(14) { 52.0 }
        val out = WatchRecovery.compute(todayHrv = 45.0, todayRhr = 52, hrvHistory = hist, rhrHistory = rhrHist)
        assertNotNull(out.recovery)
        assertTrue(out.recovery!! in 40.0..60.0)
        assertEquals(ScoreConfidence.SOLID, out.confidence)
    }

    @Test
    fun highHrvLowRhrGivesHighRecovery() {
        val hist = List(14) { 45.0 }
        val rhrHist = List(14) { 52.0 }
        val out = WatchRecovery.compute(todayHrv = 70.0, todayRhr = 46, hrvHistory = hist, rhrHistory = rhrHist)
        assertNotNull(out.recovery)
        assertTrue(out.recovery!! > 65.0)
    }

    @Test
    fun lowHrvHighRhrGivesLowRecovery() {
        val hist = List(14) { 45.0 }
        val rhrHist = List(14) { 52.0 }
        val out = WatchRecovery.compute(todayHrv = 22.0, todayRhr = 62, hrvHistory = hist, rhrHistory = rhrHist)
        assertNotNull(out.recovery)
        assertTrue(out.recovery!! < 40.0)
    }

    @Test
    fun insufficientHistoryCalibrates() {
        val out = WatchRecovery.compute(todayHrv = 45.0, todayRhr = 52, hrvHistory = listOf(45.0, 46.0), rhrHistory = listOf(52.0, 51.0))
        assertNull(out.recovery)
        assertEquals(ScoreConfidence.CALIBRATING, out.confidence)
    }

    @Test
    fun missingTodayHrvCalibrates() {
        val hist = List(14) { 45.0 }
        val out = WatchRecovery.compute(todayHrv = null, todayRhr = 52, hrvHistory = hist, rhrHistory = hist)
        assertNull(out.recovery)
        assertEquals(ScoreConfidence.CALIBRATING, out.confidence)
    }
}
