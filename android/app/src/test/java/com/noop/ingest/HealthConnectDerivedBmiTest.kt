package com.noop.ingest

import com.noop.analytics.FitnessAgeEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #951 — the Health Connect body-composition import DERIVES BMI from the day's weight plus the
 * user's profile height, because Health Connect (unlike Apple Health) carries no BMI record. This
 * pins the derive-or-skip contract [HealthConnectImporter.derivedBmi] applies: it derives only when
 * both a weight and a usable height are present, never fabricating a value from a missing height,
 * and rounds to two places to match the other body-composition series. No Health Connect client
 * needed.
 */
class HealthConnectDerivedBmiTest {

    @Test fun derivesFromWeightAndHeightRoundedToTwoPlaces() {
        // 80 kg at 178 cm -> 25.2489... -> round2 = 25.25 (same figure FitnessAgeEngine.bmi returns).
        val expected = Math.round(FitnessAgeEngine.bmi(80.0, 178.0) * 100.0) / 100.0
        assertEquals(25.25, expected, 1e-9) // guards the rounding intent
        assertEquals(25.25, HealthConnectImporter.derivedBmi(80.0, 178.0)!!, 1e-9)
    }

    @Test fun noWeightSkipsBmi() {
        // A scale that reported body-fat but no weight that day: no BMI is invented.
        assertNull(HealthConnectImporter.derivedBmi(null, 178.0))
    }

    @Test fun noHeightSkipsBmi() {
        // A caller that passes no profile height (0.0) must not fabricate a BMI from weight alone.
        assertNull(HealthConnectImporter.derivedBmi(80.0, 0.0))
        assertNull(HealthConnectImporter.derivedBmi(80.0, -1.0))
    }

    @Test fun bothMissingSkipsBmi() {
        assertNull(HealthConnectImporter.derivedBmi(null, 0.0))
    }
}
