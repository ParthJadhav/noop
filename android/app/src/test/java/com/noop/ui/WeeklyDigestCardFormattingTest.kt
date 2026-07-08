package com.noop.ui

import com.noop.analytics.PeriodComparison
import com.noop.analytics.SeriesStat
import com.noop.analytics.WeeklyMetric
import com.noop.analytics.WeeklyMetricSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Week-in-Review row formatting (#463 residuals). Pins the three display fixes:
 *  - the Effort mean follows the Effort display-scale toggle (#268) and carries its denominator,
 *    so a 0-21 user can't read "Effort 22" beside a Trends chart saying 4.6,
 *  - the sub-1% delta fallback reads "<1%" like Swift instead of a bare raw-points "0.1",
 *  - a week-over-week comparison with a 1-2 day side is ROUGH: the chip keeps its arrow + % but
 *    drops the green/rose verdict (the deferred half of the 4.2.10 fix).
 */
class WeeklyDigestCardFormattingTest {

    private fun stat(mean: Double, n: Int): SeriesStat =
        SeriesStat(mean = mean, median = mean, min = mean, max = mean, stdev = 0.0, n = n, slopePerDay = 0.0)

    private fun summary(
        metric: WeeklyMetric,
        thisMean: Double,
        thisN: Int,
        prevMean: Double,
        prevN: Int,
    ): WeeklyMetricSummary {
        val cur = stat(thisMean, thisN)
        val prev = stat(prevMean, prevN)
        val comparable = thisN > 0 && prevN > 0
        val delta = if (comparable) thisMean - prevMean else 0.0
        val pct = if (comparable && prevMean != 0.0) delta / prevMean * 100.0 else null
        val direction = when {
            !comparable || delta == 0.0 -> 0
            delta > 0 -> 1
            else -> -1
        }
        return WeeklyMetricSummary(
            metric = metric,
            thisWeek = cur,
            weekOverWeek = PeriodComparison(cur, prev, delta, pct, direction),
            baselineMean = null,
            vsBaseline = null,
        )
    }

    // ── meanText: the Effort scale toggle ───────────────────────────────────────

    @Test fun effortMeanOnTheNativeScaleShowsValueOutOf100() {
        val s = summary(WeeklyMetric.EFFORT, thisMean = 21.6, thisN = 5, prevMean = 20.0, prevN = 5)
        assertEquals("21.6 / 100", meanText(s, EffortScale.HUNDRED))
    }

    @Test fun effortMeanOnTheWhoopScaleConvertsAndShowsOutOf21() {
        // 21.6 stored × 0.21 = 4.536 → "4.5" on the 0-21 display scale.
        val s = summary(WeeklyMetric.EFFORT, thisMean = 21.6, thisN = 5, prevMean = 20.0, prevN = 5)
        assertEquals("4.5 / 21", meanText(s, EffortScale.WHOOP))
    }

    @Test fun effortCeilingMapsToTheScaleCeiling() {
        val s = summary(WeeklyMetric.EFFORT, thisMean = 100.0, thisN = 7, prevMean = 90.0, prevN = 7)
        assertEquals("21.0 / 21", meanText(s, EffortScale.WHOOP))
        assertEquals("100.0 / 100", meanText(s, EffortScale.HUNDRED))
    }

    @Test fun nonEffortMeansAreUntouchedByTheToggle() {
        val charge = summary(WeeklyMetric.CHARGE, thisMean = 70.4, thisN = 5, prevMean = 68.0, prevN = 5)
        assertEquals("70", meanText(charge, EffortScale.WHOOP))
        val rhr = summary(WeeklyMetric.RHR, thisMean = 58.2, thisN = 5, prevMean = 57.0, prevN = 5)
        assertEquals("58 bpm", meanText(rhr, EffortScale.WHOOP))
    }

    @Test fun emptyWeekMeanIsADash() {
        val s = summary(WeeklyMetric.EFFORT, thisMean = 0.0, thisN = 0, prevMean = 40.0, prevN = 5)
        assertEquals("—", meanText(s, EffortScale.HUNDRED))
    }

    // ── the engine's Effort display factor for focal sentences ──────────────────

    @Test fun effortDisplayFactorFollowsTheScaleToggle() {
        assertEquals(1.0, effortDisplayFactor(EffortScale.HUNDRED), 0.0)
        assertEquals(UnitFormatter.EFFORT_SCALE_FACTOR, effortDisplayFactor(EffortScale.WHOOP), 0.0)
    }

    // ── deltaText: the sub-1% fallback ──────────────────────────────────────────

    @Test fun percentDeltaRendersRoundedPercent() {
        val s = summary(WeeklyMetric.CHARGE, thisMean = 56.0, thisN = 5, prevMean = 50.0, prevN = 5)
        assertEquals("12%", deltaText(s))
    }

    @Test fun subOnePercentDeltaReadsLessThanOnePercent() {
        // Old fallback printed the raw points delta ("0.2"); Swift shows "<1%".
        val s = summary(WeeklyMetric.CHARGE, thisMean = 50.2, thisN = 5, prevMean = 50.0, prevN = 5)
        assertEquals("<1%", deltaText(s))
    }

    @Test fun unpercentableDeltaAlsoReadsLessThanOnePercent() {
        // previous mean 0 → pctChange null; never leak a raw stored-scale number.
        val s = summary(WeeklyMetric.EFFORT, thisMean = 40.0, thisN = 5, prevMean = 0.0, prevN = 3)
        assertEquals("<1%", deltaText(s))
    }

    @Test fun missingSideStillReadsNew() {
        val s = summary(WeeklyMetric.CHARGE, thisMean = 60.0, thisN = 5, prevMean = 0.0, prevN = 0)
        assertEquals("new", deltaText(s))
    }

    // ── rough comparisons (either side 1-2 days) ────────────────────────────────
    // The chip tone + a11y framing gate on the engine's isRoughComparison; pinned here
    // from the UI side so the display contract can't drift from the engine.

    @Test fun fullWeeksAreNotRough() {
        assertFalse(summary(WeeklyMetric.CHARGE, 56.0, 5, 50.0, 5).isRoughComparison)
        // 3 days each side is exactly the focus floor: still a real comparison.
        assertFalse(summary(WeeklyMetric.CHARGE, 56.0, 3, 50.0, 3).isRoughComparison)
    }

    @Test fun sparsePreviousWeekIsRough() {
        assertTrue(summary(WeeklyMetric.CHARGE, 41.0, 5, 72.0, 2).isRoughComparison)
    }

    @Test fun sparseCurrentWeekIsRough() {
        assertTrue(summary(WeeklyMetric.CHARGE, 72.0, 2, 41.0, 5).isRoughComparison)
    }

    @Test fun missingSideIsNotRoughItIsNew() {
        // With a side at n=0 the chip already reads "new" and wowGoodness is 0 (neutral);
        // rough is only about thin-but-present sides.
        assertFalse(summary(WeeklyMetric.CHARGE, 60.0, 5, 0.0, 0).isRoughComparison)
    }
}
