package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #589 - per-SOURCE de-overlap for Health Connect steps + calories. A phone AND a watch both write the
 * same walk to Health Connect, so summing across sources double-counts (~2x). The importer sums WITHIN a
 * source (keyed by dataOrigin.packageName) and takes the MAX source per day, mirroring the de-overlap
 * already shipped on iOS/macOS (stepsBySource.values.max()) and the Android XML importer (maxOrNull()).
 * These pin the pure reduction helpers used by both [HealthConnectImporter.import] and
 * [HealthConnectImporter.refreshTodaySteps].
 */
class HealthConnectStepsDeOverlapTest {

    @Test fun twoStepSourcesTakeMaxNotSum() {
        // Phone reports 8000, watch 9500 for the same day. Summing -> 17500 (the #589 double-count);
        // de-overlap keeps the MAX source = 9500.
        val bySource = mapOf("com.google.android.apps.fitness" to 8_000L, "com.whoop.android" to 9_500L)
        assertEquals(9_500L, HealthConnectImporter.maxSourceLong(bySource))
    }

    @Test fun twoCalorieSourcesTakeMaxNotSum() {
        // Active calories: phone 420, watch 510 -> de-overlap to MAX 510, not the 930 cross-source sum.
        val bySource = mapOf("com.google.android.apps.fitness" to 420.0, "com.whoop.android" to 510.0)
        assertEquals(510.0, HealthConnectImporter.maxSourceDouble(bySource), 0.001)
    }

    @Test fun singleSourcePassesThroughUnchanged() {
        assertEquals(7_200L, HealthConnectImporter.maxSourceLong(mapOf("com.whoop.android" to 7_200L)))
        assertEquals(640.0, HealthConnectImporter.maxSourceDouble(mapOf("com.whoop.android" to 640.0)), 0.001)
    }

    @Test fun emptyMapIsZero() {
        assertEquals(0L, HealthConnectImporter.maxSourceLong(emptyMap()))
        assertEquals(0.0, HealthConnectImporter.maxSourceDouble(emptyMap()), 0.001)
    }

    @Test fun threeSourcesTakeTheSingleLargest() {
        // A phone, a watch and a bike computer all logging the same day's calories -> the largest wins,
        // never the sum of all three.
        val bySource = mapOf("phone" to 300.0, "watch" to 880.0, "bike" to 450.0)
        assertEquals(880.0, HealthConnectImporter.maxSourceDouble(bySource), 0.001)
    }
}
