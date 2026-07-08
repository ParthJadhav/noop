package com.noop.analytics

import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Twin of the Swift StepsEstimateEngineTraceTests: the Steps test mode's two pure traces. Proves the
 * trace can never diverge from the production numbers - the 5/MG raw-counter trace's scaledSteps equals
 * AnalyticsEngine.analyzeDay(...).daily.steps EXACTLY (same wrap-aware sum, same maxStepDelta gate, same
 * ticks-per-step scaling), and the WHOOP-4 calibration trace reuses StepsEstimateEngine.calibrate verbatim.
 * No em-dashes. Pure-JVM, no Robolectric / Mockito.
 */
class StepsEstimateEngineTraceTest {

    private val profile = UserProfile()
    private val dayUtc = "2026-01-02"
    private val noonUtc = 1_767_355_200L

    private fun step(tsOffsetSec: Long, counter: Int) =
        StepSample(deviceId = "my-whoop", ts = noonUtc + tsOffsetSec, counter = counter)

    // MARK: 5/MG raw-counter trace

    @Test fun rawTotalEqualsAnalyzeDaySteps() {
        val samples = listOf(step(0, 100), step(60, 150), step(120, 220)) // 50 + 70 = 120
        val production = AnalyticsEngine.analyzeDay(day = dayUtc, steps = samples, profile = profile).daily.steps
        assertEquals(120, production)
        val lines = StepsEstimateEngineTrace.rawCounterTrace(
            daySteps = samples, dayKey = dayUtc, tzOffsetSeconds = 0L, ticksPerStep = profile.stepTicksPerStep,
        )
        val total = lines.first { it.startsWith("stepsRaw total ") }
        assertTrue(total, total.contains("scaledSteps=$production"))
        assertTrue(total.contains("rawTicks=120"))
    }

    @Test fun wrapAwareDeltaIsReportedAndCounted() {
        // 65500 -> 30 wraps: (30 - 65500) and 0xFFFF = 66; 30 -> 90 = 60. Both kept (< 512).
        val samples = listOf(step(0, 65_500), step(60, 30), step(120, 90))
        val production = AnalyticsEngine.analyzeDay(day = dayUtc, steps = samples, profile = profile).daily.steps
        assertEquals(66 + 60, production)
        val lines = StepsEstimateEngineTrace.rawCounterTrace(
            daySteps = samples, dayKey = dayUtc, tzOffsetSeconds = 0L, ticksPerStep = profile.stepTicksPerStep,
        )
        assertTrue(lines.any { it.contains("stepsRaw deltas kept=2 dropped=0") })
        assertTrue(lines.first { it.startsWith("stepsRaw total ") }.contains("scaledSteps=$production"))
        assertFalse(lines.any { it.contains("\u2014") })
    }

    @Test fun droppedDeltaIsCountedAndExcluded() {
        // 100 -> 150 (kept, 50) -> 1000 (delta 850 >= 512, DROPPED) -> 1050 (kept, 50).
        val samples = listOf(step(0, 100), step(60, 150), step(120, 1_000), step(180, 1_050))
        val production = AnalyticsEngine.analyzeDay(day = dayUtc, steps = samples, profile = profile).daily.steps
        assertEquals(100, production)
        val lines = StepsEstimateEngineTrace.rawCounterTrace(
            daySteps = samples, dayKey = dayUtc, tzOffsetSeconds = 0L, ticksPerStep = profile.stepTicksPerStep,
        )
        assertTrue(lines.any { it.contains("stepsRaw deltas kept=2 dropped=1") })
        assertTrue(lines.first { it.startsWith("stepsRaw total ") }.contains("scaledSteps=$production"))
    }

    @Test fun ticksPerStepScalingMatchesAnalyzeDay() {
        val scaledProfile = UserProfile(stepTicksPerStep = 2.0)
        val samples = listOf(step(0, 0), step(60, 100), step(120, 200)) // raw ticks = 200
        val production = AnalyticsEngine.analyzeDay(day = dayUtc, steps = samples, profile = scaledProfile).daily.steps
        val lines = StepsEstimateEngineTrace.rawCounterTrace(
            daySteps = samples, dayKey = dayUtc, tzOffsetSeconds = 0L, ticksPerStep = scaledProfile.stepTicksPerStep,
        )
        assertTrue(lines.first { it.startsWith("stepsRaw total ") }.contains("scaledSteps=$production"))
    }

    @Test fun tinyTotalRoundingToZeroRendersNoneNotZero() {
        // L7: a rawTotal that scales below 0.5 (here 1 tick / ticksPerStep 3.0 = 0.33 -> rounds to 0) makes
        // production analyzeDay return NULL (scaled>0 ? scaled : null). The trace must read "scaledSteps=none",
        // not "scaledSteps=0", so it matches the missing headline instead of implying a real zero measurement.
        val tinyProfile = UserProfile(stepTicksPerStep = 3.0)
        val samples = listOf(step(0, 100), step(60, 101)) // one kept delta of 1 tick
        val production = AnalyticsEngine.analyzeDay(day = dayUtc, steps = samples, profile = tinyProfile).daily.steps
        assertNull("a sub-0.5 scaled total is null in production", production)
        val lines = StepsEstimateEngineTrace.rawCounterTrace(
            daySteps = samples, dayKey = dayUtc, tzOffsetSeconds = 0L, ticksPerStep = tinyProfile.stepTicksPerStep,
        )
        val total = lines.first { it.startsWith("stepsRaw total ") }
        assertTrue(total, total.contains("rawTicks=1"))
        assertTrue(total, total.contains("scaledSteps=none"))
        assertFalse(total.contains("scaledSteps=0"))
    }

    @Test fun fewerThanTwoSamplesReportsNoDelta() {
        val lines = StepsEstimateEngineTrace.rawCounterTrace(
            daySteps = listOf(step(0, 100)), dayKey = dayUtc, tzOffsetSeconds = 0L, ticksPerStep = 1.0,
        )
        assertEquals(1, lines.size)
        assertTrue(lines[0].contains("counterSamples=1"))
        assertTrue(lines[0].contains("need >=2"))
    }

    @Test fun emptyCounterReportsNoRawCounterNotBroken() {
        // #810: a WHOOP 4.0 sends NO raw step counter, so daySteps is empty for it. The trace must say so
        // honestly (the device is motion-estimated), NOT emit the "counterSamples=0 ... need >=2" line that
        // read as broken. A 5/MG never hits this branch (it always banks counter rows).
        val lines = StepsEstimateEngineTrace.rawCounterTrace(
            daySteps = emptyList(), dayKey = dayUtc, tzOffsetSeconds = 0L, ticksPerStep = 1.0,
        )
        assertEquals(1, lines.size)
        assertTrue(lines[0].contains("counterSamples=0"))
        assertTrue(lines[0].contains("noRawCounter"))
        assertTrue(lines[0].contains("motion-estimated"))
        assertFalse(lines[0].contains("need >=2")) // not the misleading "broken" line
        assertFalse(lines[0].contains("\u2014")) // no em-dash
    }

    @Test fun emptyAfterDayFilterAlsoReportsNoRawCounter() {
        // daySteps has rows, but none fall on the requested day (e.g. all on a neighbouring day). After the
        // local-day filter the sorted list is empty, so the same honest noRawCounter line is emitted rather
        // than a broken-looking counterSamples=0 ... need >=2.
        val otherDay = listOf(step(2 * 86_400L, 100), step(2 * 86_400L + 60, 150))
        val lines = StepsEstimateEngineTrace.rawCounterTrace(
            daySteps = otherDay, dayKey = dayUtc, tzOffsetSeconds = 0L, ticksPerStep = 1.0,
        )
        assertEquals(1, lines.size)
        assertTrue(lines[0].contains("noRawCounter"))
    }

    // MARK: WHOOP-4 calibration trace

    @Test fun calibrationTraceReusesCalibrateVerbatim() {
        val points = listOf(
            StepsEstimateEngine.CalibrationPoint(100.0, 1_000.0),
            StepsEstimateEngine.CalibrationPoint(200.0, 2_000.0),
            StepsEstimateEngine.CalibrationPoint(300.0, 3_000.0),
        )
        val cal = StepsEstimateEngine.calibrate(points)!!
        val lines = StepsEstimateEngineTrace.calibrationTrace(points)
        val fit = lines.first { it.startsWith("stepsCal fit ") }
        val k2 = Math.round(cal.coefficient * 100.0) / 100.0
        assertTrue(fit, fit.contains("k=$k2"))
        assertTrue(fit.contains("sampleDays=${cal.sampleDays}"))
        assertTrue(fit.contains("manual=false"))
        assertEquals(3, lines.count { it.startsWith("stepsCal point ") })
        assertFalse(lines.any { it.contains("\u2014") })
    }

    @Test fun calibrationTraceNamesWithheldReason() {
        val points = listOf(
            StepsEstimateEngine.CalibrationPoint(100.0, 1_000.0),
            StepsEstimateEngine.CalibrationPoint(200.0, 2_000.0),
        )
        assertNull(StepsEstimateEngine.calibrate(points))
        val lines = StepsEstimateEngineTrace.calibrationTrace(points)
        val withheld = lines.first { it.contains("stepsCal withheld ") }
        assertNotNull(withheld)
        assertTrue(withheld.contains("reason=needsMoreDays"))
        assertTrue(withheld.contains("have=2"))
        assertTrue(withheld.contains("need=3"))
    }

    @Test fun manualOverrideTraceReportsManual() {
        val points = listOf(StepsEstimateEngine.CalibrationPoint(100.0, 1_000.0))
        val lines = StepsEstimateEngineTrace.calibrationTrace(points, manualOverride = 9.5)
        val fit = lines.first { it.startsWith("stepsCal fit ") }
        assertTrue(fit.contains("manual=true"))
        assertTrue(fit.contains("k=9.5"))
    }

    // MARK: readout parsers

    @Test fun stepsReadoutParsesScaledStepsAndEstimate() {
        assertEquals(
            120,
            StepsReadout.stepsToday(
                listOf("[steps] stepsRaw total rawTicks=120 ticksPerStep=1.0 scaledSteps=120 (steps_est for the day)"),
            ),
        )
        assertEquals(
            8421,
            StepsReadout.stepsToday(
                listOf("[steps] stepsEst day=2026-01-02 steps=8421 motion=4123.5 (motion-volume estimate)"),
            ),
        )
    }

    @Test fun calibrationStateReadoutParsesFitAndWithheld() {
        assertEquals(
            "k=10.0 sampleDays=5 confidence=0.8 manual=false",
            StepsReadout.calibrationState(
                listOf("[steps] stepsCal fit k=10.0 sampleDays=5 confidence=0.8 manual=false (k = motion-weighted median of steps/motion)"),
            ),
        )
        assertEquals(
            "not calibrated (needsMoreDays have=2 need=3)",
            StepsReadout.calibrationState(
                listOf("[steps] stepsCal withheld reason=needsMoreDays have=2 need=3 (no usable auto-fit and no manual k)"),
            ),
        )
    }
}
