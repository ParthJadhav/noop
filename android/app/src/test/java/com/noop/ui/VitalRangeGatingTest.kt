package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Range-chip gating for the Vital Signs detail (#943, ryanbr). filterVitalPoints windows off the
 * LATEST reading, so with short history every window returns the same full point set and all six
 * chips drew byte-identical charts. A range only shows something NEW once the data span EXCEEDS the
 * previous range's window, so the unlocked chips form a contiguous prefix with W always available
 * (a calibrating user is never stranded with zero ranges). These pin the unlock boundaries: n daily
 * points span n-1 days, so a range unlocks at span > 7 / 30 / 90 / 180; W and ALL are never gated (Swift parity).
 */
class VitalRangeGatingTest {

    private fun dailyPoints(count: Int, start: String = "2026-01-01"): List<Pair<String, Double>> {
        val first = java.time.LocalDate.parse(start)
        return (0 until count).map { first.plusDays(it.toLong()).toString() to 60.0 + it }
    }

    // ── span math ───────────────────────────────────────────────────────────────

    @Test fun spanIsLastMinusFirstInEpochDays() {
        assertEquals(9L, vitalHistorySpanDays(dailyPoints(10)))
        assertEquals(0L, vitalHistorySpanDays(dailyPoints(1)))
        assertEquals(0L, vitalHistorySpanDays(emptyList()))
    }

    @Test fun unparseableBoundsFallBackToZeroSpan() {
        assertEquals(0L, vitalHistorySpanDays(listOf("garbage" to 60.0, "2026-01-09" to 61.0)))
        assertEquals(0L, vitalHistorySpanDays(listOf("2026-01-01" to 60.0, "garbage" to 61.0)))
    }

    @Test fun gapsCountTowardTheSpan() {
        // Two points 60 days apart span 60 even though only 2 readings exist.
        val sparse = listOf("2026-01-01" to 60.0, "2026-03-02" to 61.0)
        assertEquals(60L, vitalHistorySpanDays(sparse))
    }

    // ── unlock boundaries (contiguous prefix, W unconditional) ──────────────────

    @Test fun weekIsAlwaysUnlocked() {
        assertEquals(listOf(VitalDetailRange.WEEK, VitalDetailRange.ALL), unlockedVitalRanges(0L))
    }

    @Test fun monthUnlocksWhenSpanExceedsAWeek() {
        assertEquals(listOf(VitalDetailRange.WEEK, VitalDetailRange.ALL), unlockedVitalRanges(7L))
        assertEquals(
            listOf(VitalDetailRange.WEEK, VitalDetailRange.MONTH, VitalDetailRange.ALL),
            unlockedVitalRanges(8L),
        )
    }

    @Test fun threeMonthUnlocksWhenSpanExceedsAMonth() {
        assertEquals(3, unlockedVitalRanges(30L).size)
        assertEquals(
            listOf(VitalDetailRange.WEEK, VitalDetailRange.MONTH, VitalDetailRange.THREE_MONTH, VitalDetailRange.ALL),
            unlockedVitalRanges(31L),
        )
    }

    @Test fun sixMonthUnlocksWhenSpanExceedsThreeMonths() {
        assertEquals(4, unlockedVitalRanges(90L).size)
        assertEquals(5, unlockedVitalRanges(91L).size)
    }

    @Test fun yearUnlocksWhenSpanExceedsSixMonths() {
        assertEquals(5, unlockedVitalRanges(180L).size)
        assertEquals(6, unlockedVitalRanges(181L).size)
    }

    @Test fun allUnlocksWhenSpanExceedsAYear() {
        assertEquals(VitalDetailRange.entries.toList(), unlockedVitalRanges(365L))
        assertEquals(VitalDetailRange.entries.toList(), unlockedVitalRanges(366L))
    }

    @Test fun largestUnlockedRangeIsTheCoercionTarget() {
        // A locked selection coerces DOWN to the largest unlocked range with a real finite window
        // that is <= the selection (never ALL), matching Swift's coercedSelection.
        val wk1 = unlockedVitalRanges(3L)   // only WEEK + ALL unlocked
        assertEquals(VitalDetailRange.WEEK, coercedVitalRange(VitalDetailRange.MONTH, wk1))
        assertEquals(VitalDetailRange.WEEK, coercedVitalRange(VitalDetailRange.YEAR, wk1))
        val span10 = unlockedVitalRanges(10L)  // WEEK + MONTH + ALL
        assertEquals(VitalDetailRange.MONTH, coercedVitalRange(VitalDetailRange.YEAR, span10))
        // An unlocked selection is kept verbatim; ALL is always selectable.
        assertEquals(VitalDetailRange.WEEK, coercedVitalRange(VitalDetailRange.WEEK, wk1))
        assertEquals(VitalDetailRange.ALL, coercedVitalRange(VitalDetailRange.ALL, wk1))
    }

    // ── the gating rule really is the identical-window dedup rule ───────────────

    @Test fun lockedRangeWouldHaveDrawnTheSamePointsAsItsPredecessor() {
        // 10 daily points, span 9: W (7 points) differs from M (all 10), so M is unlocked;
        // 3M returns the identical set as M, so 3M is locked.
        val points = dailyPoints(10)
        val unlocked = unlockedVitalRanges(vitalHistorySpanDays(points))
        assertEquals(listOf(VitalDetailRange.WEEK, VitalDetailRange.MONTH, VitalDetailRange.ALL), unlocked)
        assertEquals(7, filterVitalPoints(points, VitalDetailRange.WEEK).size)
        assertEquals(10, filterVitalPoints(points, VitalDetailRange.MONTH).size)
        assertEquals(
            filterVitalPoints(points, VitalDetailRange.MONTH),
            filterVitalPoints(points, VitalDetailRange.THREE_MONTH),
        )
    }

    @Test fun filterWindowsOffTheLatestReadingInclusive() {
        // The WEEK window is latestDate-6..latestDate, so exactly the last 7 daily points survive.
        val points = dailyPoints(30)
        val week = filterVitalPoints(points, VitalDetailRange.WEEK)
        assertEquals(7, week.size)
        assertEquals(points.takeLast(7), week)
    }
}
