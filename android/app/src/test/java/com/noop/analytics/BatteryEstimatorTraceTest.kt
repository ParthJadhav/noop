package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Twin of the Swift BatteryEstimatorTraceTests: same fixtures, same trace lines, and the same proof that
 *  the emitter never changes the engine value estimate() returns (#713, Test Centre). No em-dashes. */
class BatteryEstimatorTraceTest {

    private val h = 3600L

    @Test fun traceNullWhenNoSamples() {
        val (estimate, lines) = BatteryEstimator.estimateTrace(
            emptyList(), BatteryEstimator.ratedLifeHoursWhoop5)
        assertNull(estimate)
        assertEquals(listOf("battery series=0 readings, no reading to anchor to"), lines)
    }

    @Test fun traceEmitsSeriesChargeStepRunSlopeAndGate() {
        val samples = listOf(0L to 100.0, 4 * h to 70.0, 5 * h to 100.0, 11 * h to 88.0)
        val (estimate, lines) = BatteryEstimator.estimateTrace(
            samples, BatteryEstimator.ratedLifeHoursWhoop5)

        // The emitter must NOT change the engine result.
        assertEquals(BatteryEstimator.estimate(samples, BatteryEstimator.ratedLifeHoursWhoop5), estimate)

        assertEquals(listOf(
            "battery series=4 readings span 0..39600s",
            "battery read t=0s soc=100.0",
            "battery read t=14400s soc=70.0",
            "battery read t=18000s soc=100.0",
            "battery read t=39600s soc=88.0",
            "battery chargeStep at t=18000s +30.0pp (>chargeStepPct 1.0)",
            "battery dischargeRun start=18000s span=6.0h drop=12.0pp",
            "battery slope=2.0pct/h fitted from run endpoints",
            "battery gate minSpanHours 2.0 PASS, minDropPct 2.0 PASS -> source=measured",
        ), lines)
    }

    @Test fun tracePartialTopUpFitsPreTopUpSegment() {
        // #8: a partial top-up (40->55, below nearFullPct 90) does NOT anchor the run. The trace reports it
        // as a partialTopUp, the fit prefers the long pre-top-up discharge (100->40 over 60h = 1 %/h), and
        // source stays measured at an honest ~53h, not the inflated short-tail rate.
        val samples = listOf(0L to 100.0, 60 * h to 40.0, 61 * h to 55.0, 64 * h to 53.0)
        val (estimate, lines) = BatteryEstimator.estimateTrace(
            samples, BatteryEstimator.ratedLifeHoursWhoop5)

        // The emitter must NOT change the engine result.
        assertEquals(BatteryEstimator.estimate(samples, BatteryEstimator.ratedLifeHoursWhoop5), estimate)

        assertEquals(listOf(
            "battery series=4 readings span 0..230400s",
            "battery read t=0s soc=100.0",
            "battery read t=216000s soc=40.0",
            "battery read t=219600s soc=55.0",
            "battery read t=230400s soc=53.0",
            "battery partialTopUp at t=219600s +15.0pp (<nearFullPct 90.0) -> fit pre-top-up segment",
            "battery dischargeRun start=0s span=60.0h drop=60.0pp",
            "battery slope=1.0pct/h fitted from run endpoints",
            "battery gate minSpanHours 2.0 PASS, minDropPct 2.0 PASS -> source=measured",
        ), lines)
        // No full-charge chargeStep line: the only rise here is a partial top-up.
        assertFalse(lines.any { it.startsWith("battery chargeStep") })
    }

    @Test fun traceGateDropToRatedWhenDropTooSmall() {
        val samples = listOf(0L to 100.0, 10 * h to 99.0)
        val (estimate, lines) = BatteryEstimator.estimateTrace(
            samples, BatteryEstimator.ratedLifeHoursWhoop5)
        assertEquals(BatteryEstimator.Source.RATED, estimate?.source)
        assertTrue(lines.contains(
            "battery gate minSpanHours 2.0 PASS, minDropPct 2.0 FAIL -> source=rated"))
        assertFalse(lines.any { it.startsWith("battery chargeStep") })
    }
}
