package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Golden-fixture parity tests for the Kotlin WeeklyDigest engine. Mirrors the Swift
 * WeeklyDigestTests so the two platforms stay byte-identical (#208).
 */
class WeeklyDigestTest {

    // MARK: - Pure week math

    @Test fun mondayOfWeek() {
        // 2026-06-13 is a Saturday → its Monday is 2026-06-08.
        assertEquals("2026-06-08", WeeklyDigestEngine.mondayOfWeek("2026-06-13"))
        assertEquals("2026-06-08", WeeklyDigestEngine.mondayOfWeek("2026-06-08")) // a Monday
        assertEquals("2026-06-08", WeeklyDigestEngine.mondayOfWeek("2026-06-14")) // a Sunday
    }

    @Test fun weekdaySakamoto() {
        // 0=Sun … 6=Sat.
        assertEquals(1, WeeklyDigestEngine.weekday(2026, 6, 8))   // Monday
        assertEquals(6, WeeklyDigestEngine.weekday(2026, 6, 13))  // Saturday
        assertEquals(0, WeeklyDigestEngine.weekday(2026, 6, 14))  // Sunday
        assertEquals(6, WeeklyDigestEngine.weekday(2000, 1, 1))   // Saturday
    }

    @Test fun addDaysCrossesMonthAndYear() {
        assertEquals("2026-06-07", WeeklyDigestEngine.addDays("2026-06-08", -1))
        assertEquals("2026-06-01", WeeklyDigestEngine.addDays("2026-06-08", -7))
        assertEquals("2026-05-31", WeeklyDigestEngine.addDays("2026-06-08", -8))  // month rollback
        assertEquals("2025-12-31", WeeklyDigestEngine.addDays("2026-01-01", -1))  // year rollback
        assertEquals("2026-06-14", WeeklyDigestEngine.addDays("2026-06-08", 6))
    }

    @Test fun addDaysLeapYear() {
        assertEquals("2024-02-29", WeeklyDigestEngine.addDays("2024-02-28", 1)) // leap year
        assertEquals("2024-03-01", WeeklyDigestEngine.addDays("2024-02-29", 1))
        assertEquals("2026-03-01", WeeklyDigestEngine.addDays("2026-02-28", 1)) // non-leap
        assertNull(WeeklyDigestEngine.parseYMD("2026-02-29"))                   // not a real date
    }

    @Test fun badAnchorGivesEmptyDigest() {
        val d = WeeklyDigestEngine.build(emptyMap(), "not-a-date")
        assertTrue(d.isEmpty)
        assertEquals(0, d.daysWithData)
        assertEquals(WeeklyMetric.values().size, d.metrics.size)
        assertEquals(BalanceRead.INSUFFICIENT, d.balance)
        assertTrue(d.focalPoints.isEmpty())
    }

    // MARK: - Window split (golden fixture)

    @Test fun weekSplitAndWoW() {
        val charge = HashMap<String, Double>()
        for (day in 8..14) charge[fmt(day)] = 70.0   // this week
        for (day in 1..7) charge[fmt(day)] = 60.0    // last week

        val digest = WeeklyDigestEngine.build(mapOf(WeeklyMetric.CHARGE to charge), "2026-06-13")
        assertEquals("2026-06-08", digest.weekStart)
        assertEquals("2026-06-14", digest.weekEnd)
        assertEquals(7, digest.daysWithData)

        val c = digest.summary(WeeklyMetric.CHARGE)!!
        assertEquals(7, c.thisWeek.n)
        assertEquals(70.0, c.thisWeek.mean, 1e-9)
        assertEquals(7, c.weekOverWeek.previous.n)
        assertEquals(60.0, c.weekOverWeek.previous.mean, 1e-9)
        assertEquals(10.0, c.wowDelta, 1e-9)
        assertEquals(100.0 / 6.0, c.weekOverWeek.pctChange!!, 1e-6)
        assertEquals(1, c.wowGoodness)   // Charge up → good
    }

    @Test fun daysOutsideTheWeekAreIgnored() {
        val charge = HashMap<String, Double>()
        for (day in 8..14) charge[fmt(day)] = 70.0
        charge["2026-06-15"] = 999.0  // next Monday — excluded
        charge["2026-06-07"] = 999.0  // last Sunday — excluded
        val c = WeeklyDigestEngine.build(mapOf(WeeklyMetric.CHARGE to charge), "2026-06-10")
            .summary(WeeklyMetric.CHARGE)!!
        assertEquals(7, c.thisWeek.n)
        assertEquals(70.0, c.thisWeek.max, 1e-9)
    }

    // MARK: - vs-baseline

    @Test fun vsBaselineUsesFourPriorWeeks() {
        val hrv = HashMap<String, Double>()
        for (day in 8..14) hrv[fmt(day)] = 60.0   // this week
        for (day in 1..7) hrv[fmt(day)] = 55.0    // last week (not baseline)
        for (day in daysBetween("2026-05-04", "2026-05-31")) hrv[day] = 50.0  // 4 weeks baseline

        val h = WeeklyDigestEngine.build(mapOf(WeeklyMetric.HRV to hrv), "2026-06-13")
            .summary(WeeklyMetric.HRV)!!
        assertEquals(50.0, h.baselineMean!!, 1e-9)
        assertEquals(10.0, h.vsBaseline!!, 1e-9)
    }

    // MARK: - Sleep consistency

    @Test fun sleepConsistencyIsSdOfRest() {
        // 80,82,84,86,88,90,92 → sample SD ≈ 4.3205.
        val rest = HashMap<String, Double>()
        val vals = listOf(80.0, 82.0, 84.0, 86.0, 88.0, 90.0, 92.0)
        vals.forEachIndexed { i, v -> rest[fmt(8 + i)] = v }
        val d = WeeklyDigestEngine.build(mapOf(WeeklyMetric.REST to rest), "2026-06-10")
        assertEquals(4.320493798938574, d.sleepConsistencySD!!, 1e-9)
    }

    @Test fun sleepConsistencyNullWithOneNight() {
        val rest = mapOf("2026-06-08" to 85.0)
        val d = WeeklyDigestEngine.build(mapOf(WeeklyMetric.REST to rest), "2026-06-10")
        assertNull(d.sleepConsistencySD)
    }

    // MARK: - Balance read

    @Test fun balanceOverreaching() {
        val effort = HashMap<String, Double>(); val charge = HashMap<String, Double>()
        for (day in 8..14) { effort[fmt(day)] = 80.0; charge[fmt(day)] = 50.0 }
        val d = WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.EFFORT to effort, WeeklyMetric.CHARGE to charge), "2026-06-10",
        )
        assertEquals(BalanceRead.OVERREACHING, d.balance)
    }

    @Test fun balanceUnderloaded() {
        val effort = HashMap<String, Double>(); val charge = HashMap<String, Double>()
        for (day in 8..14) { effort[fmt(day)] = 40.0; charge[fmt(day)] = 75.0 }
        val d = WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.EFFORT to effort, WeeklyMetric.CHARGE to charge), "2026-06-10",
        )
        assertEquals(BalanceRead.UNDERLOADED, d.balance)
    }

    @Test fun balanceBalanced() {
        val effort = HashMap<String, Double>(); val charge = HashMap<String, Double>()
        for (day in 8..14) { effort[fmt(day)] = 55.0; charge[fmt(day)] = 60.0 }
        val d = WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.EFFORT to effort, WeeklyMetric.CHARGE to charge), "2026-06-10",
        )
        assertEquals(BalanceRead.BALANCED, d.balance)
    }

    @Test fun balanceInsufficientWithTooFewDays() {
        val effort = HashMap<String, Double>(); val charge = HashMap<String, Double>()
        for (day in 8..9) { effort[fmt(day)] = 80.0; charge[fmt(day)] = 50.0 }
        val d = WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.EFFORT to effort, WeeklyMetric.CHARGE to charge), "2026-06-10",
        )
        assertEquals(BalanceRead.INSUFFICIENT, d.balance)
    }

    // MARK: - Focal points

    @Test fun focalPointSurfacesBiggestMover() {
        val charge = HashMap<String, Double>()
        for (day in 8..14) charge[fmt(day)] = 80.0
        for (day in 1..7) charge[fmt(day)] = 55.0
        val d = WeeklyDigestEngine.build(mapOf(WeeklyMetric.CHARGE to charge), "2026-06-13")
        assertFalse(d.focalPoints.isEmpty())
        val top = d.focalPoints[0]
        assertTrue(top, top.contains("Charge"))
        assertTrue(top, top.contains("up"))
        assertTrue(top, top.contains("good sign"))
    }

    @Test fun restingHrRiseReadsAsWorthALook() {
        val rhr = HashMap<String, Double>()
        for (day in 8..14) rhr[fmt(day)] = 60.0
        for (day in 1..7) rhr[fmt(day)] = 52.0
        val d = WeeklyDigestEngine.build(mapOf(WeeklyMetric.RHR to rhr), "2026-06-13")
        val line = d.focalPoints.firstOrNull() ?: ""
        assertTrue(line, line.contains("Resting HR"))
        assertTrue(line, line.contains("worth a look"))
    }

    @Test fun steadyWeekGivesCalmLine() {
        val charge = HashMap<String, Double>(); val effort = HashMap<String, Double>(); val rest = HashMap<String, Double>()
        for (day in 1..14) { charge[fmt(day)] = 65.0; effort[fmt(day)] = 63.0; rest[fmt(day)] = 84.0 }
        val d = WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.CHARGE to charge, WeeklyMetric.EFFORT to effort, WeeklyMetric.REST to rest),
            "2026-06-13",
        )
        assertEquals(1, d.focalPoints.size)
        assertTrue(d.focalPoints[0], d.focalPoints[0].lowercase().contains("steady"))
    }

    @Test fun sparseWeekSaysTooEarlyNotSteady() {
        // Current week has only 2 days, with a big raw drop vs a full previous week — the
        // per-metric chips would show a large %, but 2 days can't anchor a week-over-week
        // trend. The summary must defer ("too early") rather than claim a steady week (#463).
        val charge = HashMap<String, Double>()
        for (day in 1..7) charge[fmt(day)] = 70.0   // last week, full
        charge[fmt(8)] = 40.0                        // this week, day 1
        charge[fmt(9)] = 40.0                        // this week, day 2
        val d = WeeklyDigestEngine.build(mapOf(WeeklyMetric.CHARGE to charge), "2026-06-09")
        assertEquals(2, d.summary(WeeklyMetric.CHARGE)!!.thisWeek.n)   // sparse current week
        assertEquals(1, d.focalPoints.size)
        val line = d.focalPoints[0]
        assertTrue(line, line.contains("too early"))
        assertTrue(line, line.contains("2 days"))
        assertFalse(line, line.lowercase().contains("steady"))
    }

    @Test fun sparsePreviousWeekSaysRoughNotSteady() {
        // The mirror image of the sparse-current case (typical new user in week 2): the
        // CURRENT week has plenty of days, but LAST week only had 2 — movers are gated on
        // previous.n >= MIN_DAYS_FOR_FOCUS, so nothing surfaces, while the chips show a big
        // raw % off those 2 days. The summary must call the comparison rough rather than
        // claim a steady week with nothing moved (#463, the residual half).
        val charge = HashMap<String, Double>()
        charge["2026-06-06"] = 70.0                  // last week, day 1
        charge["2026-06-07"] = 74.0                  // last week, day 2
        for (day in 8..12) charge[fmt(day)] = 41.0   // this week, 5 days
        val d = WeeklyDigestEngine.build(mapOf(WeeklyMetric.CHARGE to charge), "2026-06-12")
        assertEquals(5, d.summary(WeeklyMetric.CHARGE)!!.thisWeek.n)              // full-enough current week
        assertEquals(2, d.summary(WeeklyMetric.CHARGE)!!.weekOverWeek.previous.n) // sparse previous week
        assertEquals(1, d.focalPoints.size)
        val line = d.focalPoints[0]
        assertTrue(line, line.contains("Last week"))
        assertTrue(line, line.contains("rough"))
        assertTrue(line, line.contains("2 days"))
        assertFalse(line, line.lowercase().contains("steady"))
        assertFalse(line, line.contains("too early"))
    }

    // MARK: - Rough-comparison flag (chips must not imply confidence on a sparse side)

    @Test fun isRoughComparisonFlagsSparseSides() {
        // Sparse CURRENT week (2 days) vs full previous → rough.
        val charge = HashMap<String, Double>()
        for (day in 1..7) charge[fmt(day)] = 70.0
        charge[fmt(8)] = 40.0; charge[fmt(9)] = 40.0
        val sparseCurrent = WeeklyDigestEngine.build(mapOf(WeeklyMetric.CHARGE to charge), "2026-06-09")
        assertTrue(sparseCurrent.summary(WeeklyMetric.CHARGE)!!.isRoughComparison)

        // Sparse PREVIOUS week (2 days) vs full-enough current → rough.
        val rest = HashMap<String, Double>()
        rest[fmt(6)] = 80.0; rest[fmt(7)] = 82.0
        for (day in 8..12) rest[fmt(day)] = 85.0
        val sparsePrevious = WeeklyDigestEngine.build(mapOf(WeeklyMetric.REST to rest), "2026-06-12")
        assertTrue(sparsePrevious.summary(WeeklyMetric.REST)!!.isRoughComparison)

        // Both weeks fully populated → a real comparison, not rough.
        val hrv = HashMap<String, Double>()
        for (day in 1..14) hrv[fmt(day)] = 60.0
        val full = WeeklyDigestEngine.build(mapOf(WeeklyMetric.HRV to hrv), "2026-06-12")
        assertFalse(full.summary(WeeklyMetric.HRV)!!.isRoughComparison)

        // No previous week at all → there is no comparison to call rough.
        val rhr = HashMap<String, Double>()
        rhr[fmt(8)] = 55.0; rhr[fmt(9)] = 56.0
        val noPrevious = WeeklyDigestEngine.build(mapOf(WeeklyMetric.RHR to rhr), "2026-06-09")
        assertFalse(noPrevious.summary(WeeklyMetric.RHR)!!.isRoughComparison)
    }

    // MARK: - Effort display factor (the #268 scale toggle reaches the prose)

    @Test fun effortDisplayFactorDefaultIsByteIdentical() {
        // factor 1.0 (and the omitted default) must not change a single character of any
        // focal point — this pins every existing sentence for existing callers.
        val effort = HashMap<String, Double>(); val charge = HashMap<String, Double>()
        for (day in 8..14) { effort[fmt(day)] = 25.0; charge[fmt(day)] = 60.0 }
        for (day in 1..7) { effort[fmt(day)] = 35.0; charge[fmt(day)] = 60.0 }
        val input = mapOf(WeeklyMetric.EFFORT to effort, WeeklyMetric.CHARGE to charge)
        val implicitDefault = WeeklyDigestEngine.build(input, "2026-06-13")
        val explicitOne = WeeklyDigestEngine.build(input, "2026-06-13", effortDisplayFactor = 1.0)
        assertEquals(implicitDefault, explicitOne)
        assertTrue(implicitDefault.focalPoints[0], implicitDefault.focalPoints[0].contains("(avg 25 vs 35)"))
    }

    @Test fun effortDisplayFactorRescalesEffortAveragesOnly() {
        // Effort mover 25 vs 35 (stored 0–100). On the 0–21 scale (factor 0.21) the prose
        // averages must read 5 vs 7 while the % (scale-invariant) stays 29%.
        val effort = HashMap<String, Double>()
        for (day in 8..14) effort[fmt(day)] = 25.0
        for (day in 1..7) effort[fmt(day)] = 35.0
        val scaled = WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.EFFORT to effort), "2026-06-13", effortDisplayFactor = 0.21,
        )
        val line = scaled.focalPoints[0]
        assertTrue(line, line.contains("(avg 5 vs 7)"))
        assertTrue(line, line.contains("29%"))

        // A non-Effort mover is untouched by the factor.
        val chargeOnly = HashMap<String, Double>()
        for (day in 8..14) chargeOnly[fmt(day)] = 80.0
        for (day in 1..7) chargeOnly[fmt(day)] = 55.0
        val input = mapOf(WeeklyMetric.CHARGE to chargeOnly)
        val a = WeeklyDigestEngine.build(input, "2026-06-13")
        val b = WeeklyDigestEngine.build(input, "2026-06-13", effortDisplayFactor = 0.21)
        assertEquals(a.focalPoints, b.focalPoints)
        assertTrue(b.focalPoints[0], b.focalPoints[0].contains("(avg 80 vs 55)"))
    }

    @Test fun effortDisplayFactorRescalesPtsFallback() {
        // Previous Effort mean is 0 → pctChange is null → the "pts" fallback renders, and it
        // must be in display units too (10 stored pts × 0.21 = 2.1 pts on the 0–21 scale).
        val effort = HashMap<String, Double>()
        for (day in 8..14) effort[fmt(day)] = 10.0
        for (day in 1..7) effort[fmt(day)] = 0.0
        val d = WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.EFFORT to effort), "2026-06-13", effortDisplayFactor = 0.21,
        )
        val line = d.focalPoints[0]
        assertTrue(line, line.contains("2.1 pts"))
        assertTrue(line, line.contains("(avg 2 vs 0)"))
    }

    @Test fun focalPointsCappedAtTwo() {
        val charge = HashMap<String, Double>(); val effort = HashMap<String, Double>(); val hrv = HashMap<String, Double>()
        for (day in 8..14) { charge[fmt(day)] = 85.0; effort[fmt(day)] = 30.0; hrv[fmt(day)] = 75.0 }
        for (day in 1..7) { charge[fmt(day)] = 50.0; effort[fmt(day)] = 70.0; hrv[fmt(day)] = 45.0 }
        val d = WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.CHARGE to charge, WeeklyMetric.EFFORT to effort, WeeklyMetric.HRV to hrv),
            "2026-06-13",
        )
        assertTrue(d.focalPoints.size in 1..2)
    }

    // MARK: - Determinism

    @Test fun deterministicAcrossRuns() {
        val charge = HashMap<String, Double>(); val hrv = HashMap<String, Double>()
        for (day in 1..14) {
            charge[fmt(day)] = ((day * 7) % 40 + 50).toDouble()
            hrv[fmt(day)] = ((day * 13) % 30 + 45).toDouble()
        }
        val input = mapOf(WeeklyMetric.CHARGE to charge, WeeklyMetric.HRV to hrv)
        val a = WeeklyDigestEngine.build(input, "2026-06-13")
        val b = WeeklyDigestEngine.build(input, "2026-06-13")
        assertEquals(a, b)
    }

    // MARK: - Helpers

    private fun fmt(day: Int): String = "2026-06-%02d".format(day)

    private fun daysBetween(start: String, end: String): List<String> {
        val out = mutableListOf<String>()
        var cur = start
        while (cur <= end) {
            out.add(cur)
            cur = WeeklyDigestEngine.addDays(cur, 1)
        }
        return out
    }
}
