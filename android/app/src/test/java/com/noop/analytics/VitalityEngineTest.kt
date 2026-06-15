package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirror of the Swift VitalityEngineTests — identical inputs + expected numbers (parity guard). */
class VitalityEngineTest {

    @Test fun averageReadsAtTheirAge() {
        val r = VitalityEngine.compute(VitalityEngine.Inputs(
            chronoAge = 40.0, restingHR = 65.0, vo2max = 45.0, expectedVO2max = 45.0,
            sleepHours = 7.5, sleepConsistency = 0.75, rmssd = 45.0, rmssdNorm = 45.0, steps = 7000.0))!!
        assertEquals(40.0, r.bodyAge, 0.01)
        assertEquals(50.0, r.vitality, 0.01)
        assertEquals(0.0, r.deltaYears, 0.01)
        assertEquals(6, r.factorsUsed)
    }

    @Test fun healthyIsYounger() {
        val r = VitalityEngine.compute(VitalityEngine.Inputs(
            chronoAge = 40.0, restingHR = 52.0, vo2max = 55.5, expectedVO2max = 45.0,
            sleepHours = 7.5, sleepConsistency = 0.9, rmssd = 54.0, rmssdNorm = 45.0, steps = 11000.0))!!
        assertEquals(32.42, r.bodyAge, 0.1)
        assertEquals(68.95, r.vitality, 0.2)
        assertTrue(r.deltaYears > 0)
    }

    @Test fun unhealthyIsOlder() {
        val r = VitalityEngine.compute(VitalityEngine.Inputs(
            chronoAge = 40.0, restingHR = 80.0, vo2max = 34.5, expectedVO2max = 45.0,
            sleepHours = 5.5, sleepConsistency = 0.5, rmssd = 31.5, rmssdNorm = 45.0, steps = 3000.0))!!
        assertEquals(49.71, r.bodyAge, 0.1)
        assertEquals(25.73, r.vitality, 0.2)
        assertTrue(r.deltaYears < 0)
    }

    @Test fun nilBelowMinFactors() {
        assertNull(VitalityEngine.compute(VitalityEngine.Inputs(
            chronoAge = 40.0, restingHR = 65.0, sleepHours = 7.5)))
        assertNotNull(VitalityEngine.compute(VitalityEngine.Inputs(
            chronoAge = 40.0, restingHR = 65.0, sleepHours = 7.5, sleepConsistency = 0.75)))
    }

    @Test fun clamps() {
        val young = VitalityEngine.compute(VitalityEngine.Inputs(
            chronoAge = 22.0, restingHR = 40.0, vo2max = 70.0, expectedVO2max = 40.0,
            sleepHours = 7.5, sleepConsistency = 1.0, rmssd = 90.0, rmssdNorm = 45.0, steps = 11000.0))!!
        assertTrue(young.bodyAge >= VitalityEngine.minBodyAge)
        assertTrue(young.vitality in 0.0..100.0)

        val old = VitalityEngine.compute(VitalityEngine.Inputs(
            chronoAge = 85.0, restingHR = 110.0, vo2max = 12.0, expectedVO2max = 35.0,
            sleepHours = 3.0, sleepConsistency = 0.1, rmssd = 8.0, rmssdNorm = 30.0, steps = 200.0))!!
        assertTrue(old.bodyAge <= VitalityEngine.maxBodyAge)
        assertTrue(old.vitality >= 0.0)
    }

    @Test fun rmssdNormByAge() {
        assertEquals(47.0, VitalityEngine.rmssdNorm(20.0), 0.01)
        assertEquals(33.0, VitalityEngine.rmssdNorm(40.0), 0.01)
        assertEquals(31.0, VitalityEngine.rmssdNorm(45.0), 0.01)
        assertEquals(20.0, VitalityEngine.rmssdNorm(90.0), 0.01)
    }

    @Test fun sleepConsistencyTest() {
        assertEquals(1.0, VitalityEngine.sleepConsistency(listOf(7.0, 7.0, 7.0, 7.0))!!, 1e-9)
        assertEquals(0.857, VitalityEngine.sleepConsistency(listOf(6.0, 8.0, 6.0, 8.0))!!, 0.005)
        assertNull(VitalityEngine.sleepConsistency(listOf(7.0, 7.0)))
    }

    @Test fun contributionSigns() {
        val low = VitalityEngine.contributions(VitalityEngine.Inputs(chronoAge = 40.0, restingHR = 50.0))
            .first { it.key == "rhr" }
        assertTrue(low.lnHazard < 0)
        val high = VitalityEngine.contributions(VitalityEngine.Inputs(chronoAge = 40.0, restingHR = 85.0))
            .first { it.key == "rhr" }
        assertTrue(high.lnHazard > 0)
    }
}
