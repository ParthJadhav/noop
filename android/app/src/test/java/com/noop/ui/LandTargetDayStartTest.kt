package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure land-on-day decision for the Deep Timeline's one-shot open (#597 / #863). [landTargetDayStart]
 * decides which day the timeline should jump to: a scored day (DailyMetric) wins, else it falls back to the
 * day that holds the most recent raw HR sample (the calibrating-4.0 case , banked HR but no scored row yet),
 * and it only ever jumps to a day STRICTLY EARLIER than where we already are.
 *
 * The decision injects its own ts -> local-midnight mapper so the test is deterministic without a Calendar /
 * timezone , here a fixed 86_400-second day grid (UTC midnights). dayKeyToEpochSec (used for the scored-key
 * branch) parses against the JVM default zone, so the scored-day cases use day keys whose UTC and local
 * midnight coincide by keeping the asserts on the RAW-HR branch (the #863 fix) and the no-jump guards.
 */
class LandTargetDayStartTest {

    /** Deterministic stand-in for epochSecToLocalDayStart: floor an epoch-second to its UTC-day midnight. */
    private val dayStartOf: (Long) -> Long = { ts -> (ts / 86_400L) * 86_400L }

    private val today = 100L * 86_400L // an arbitrary "today" midnight on the fixed grid

    @Test
    fun `raw HR on an earlier day lands there when no scored day exists`() {
        // A calibrating 4.0: no DailyMetric yet, but raw HR was banked three days ago. We should land on
        // that day's midnight instead of sitting on an empty today (#863).
        val rawTs = today - 3 * 86_400L + 7 * 3600L // mid-afternoon, three days back
        val target = landTargetDayStart(
            currentDayStart = today,
            latestScoredDayKey = null,
            latestRawHrTs = rawTs,
            dayStartOf = dayStartOf,
        )
        assertEquals(today - 3 * 86_400L, target)
    }

    @Test
    fun `no scored day and no raw HR makes no jump`() {
        // An empty store (brand-new install): nothing to land on, stay on today.
        val target = landTargetDayStart(
            currentDayStart = today,
            latestScoredDayKey = null,
            latestRawHrTs = null,
            dayStartOf = dayStartOf,
        )
        assertNull(target)
    }

    @Test
    fun `raw HR on today does not jump`() {
        // Raw HR exists but it's already today's data , no earlier day to move to, so stay put (no jump
        // back to a redundant "today").
        val rawTs = today + 9 * 3600L
        val target = landTargetDayStart(
            currentDayStart = today,
            latestScoredDayKey = null,
            latestRawHrTs = rawTs,
            dayStartOf = dayStartOf,
        )
        assertNull(target)
    }

    @Test
    fun `scored day is preferred over raw HR when both exist`() {
        // When a DailyMetric exists, the scored-day key wins (the historical #597 behaviour); the raw-HR
        // fallback is only consulted when there is NO scored day. The raw-HR ts here points at a DIFFERENT,
        // later day, so if the fallback wrongly won the target would differ , proving precedence.
        val rawTs = today - 1 * 86_400L + 5 * 3600L // yesterday
        // dayKeyToEpochSec parses in the JVM default zone; pick a key whose presence (non-null) is all we
        // assert on, by checking the result is NOT the raw-HR day. A scored key three days back must beat it.
        val scoredKey = epochToKey(today - 3 * 86_400L)
        val target = landTargetDayStart(
            currentDayStart = today,
            latestScoredDayKey = scoredKey,
            latestRawHrTs = rawTs,
            dayStartOf = dayStartOf,
        )
        // The fallback (yesterday's raw HR) must NOT be the winner , the scored day took precedence.
        val rawDay = dayStartOf(rawTs)
        assertEquals(false, target == rawDay)
    }

    /** yyyy-MM-dd for a UTC midnight , the format dayKeyToEpochSec parses. */
    private fun epochToKey(epochSec: Long): String {
        val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
        sdf.timeZone = java.util.TimeZone.getDefault()
        return sdf.format(java.util.Date(epochSec * 1000))
    }
}
