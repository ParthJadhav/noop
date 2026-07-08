package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin twin of the macOS IntelligenceWatchRecoveryTests: the source-only Charge fold (#823). An
 * import-only user (Health Connect / Oura-Fitbit-Garmin / Apple Health) has DAILY aggregates (HRV + resting
 * HR, recovery null) but no raw stream, so the raw-HR scoring loop never scores their days.
 * [IntelligenceEngine.watchRecoveries] folds the TRAILING HRV+RHR history into the cross-lane
 * [WatchRecovery] engine and writes a recovery + confidence per day, staying null/CALIBRATING until there is
 * enough baseline (never a fabricated number). Pure (no Room) , the SAME logic analyzeRecent ships per day.
 */
class IntelligenceWatchRecoveryTest {

    private fun importRow(day: String, hrv: Double?, rhr: Int?) = DailyMetric(
        deviceId = "oura-import", day = day, avgHrv = hrv, restingHr = rhr, recovery = null,
    )

    @Test
    fun tenImportDaysGiveLatestDayANonCalibratingRecovery() {
        val rows = (1..10).map { importRow("2026-06-%02d".format(it), 50.0, 50) }
        val scored = IntelligenceEngine.watchRecoveries(rows)

        assertEquals(10, scored.size)
        val latest = scored.last()
        assertEquals("2026-06-10", latest.day)
        assertNotNull("an import-only day with enough history must score a Charge (#823)", latest.recovery)
        assertFalse(latest.confidence == ScoreConfidence.CALIBRATING)
    }

    @Test
    fun earlyDaysStayCalibrating() {
        val rows = (1..10).map { importRow("2026-06-%02d".format(it), 50.0, 50) }
        val scored = IntelligenceEngine.watchRecoveries(rows)
        assertNull(scored[0].recovery)
        assertEquals(ScoreConfidence.CALIBRATING, scored[0].confidence)
        assertNull(scored[1].recovery)
    }

    @Test
    fun strapScoredDayIsSkipped() {
        val rows = (1..10).map { importRow("2026-06-%02d".format(it), 50.0, 50) }
        val scored = IntelligenceEngine.watchRecoveries(rows, strapRecoveryDays = setOf("2026-06-10"))
        assertEquals(9, scored.size)
        assertTrue(scored.none { it.day == "2026-06-10" })
    }

    @Test
    fun sparseImportStaysCalibratingNeverFabricated() {
        val rows = (1..3).map { importRow("2026-06-%02d".format(it), 50.0, 50) }
        val scored = IntelligenceEngine.watchRecoveries(rows)
        assertTrue(scored.all { it.recovery == null })
        assertTrue(scored.all { it.confidence == ScoreConfidence.CALIBRATING })
    }

    @Test
    fun unorderedInputIsSortedBeforeFolding() {
        val ordered = (1..10).map { importRow("2026-06-%02d".format(it), 50.0, 50) }
        val scored = IntelligenceEngine.watchRecoveries(ordered.shuffled())
        assertEquals(ordered.map { it.day }, scored.map { it.day })
        assertNotNull(scored.last().recovery)
    }
}
