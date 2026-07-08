package com.noop.ui

import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #940 (Android twin of SleepPhantomNightFallbackTests.swift): an impossible hand-edit (bed rolled
 * across midnight onto the COMING evening) produced a future-dated, all-awake "phantom" night. It
 * owned the tab's newest day; [buildSleepModel] returned null for that day (no stage minutes), and
 * the screen then hid EVERY full-history tile / ledger / trend behind the null model even though the
 * user's data was intact. The fix: [fallbackSleepModel] re-anchors the full-history surfaces to the
 * newest stage-bearing day, and the hero keeps the phantom day (edit affordance reachable) with the
 * honest no-stage-data fallback. These feed the merge chain the impossible edited window and assert
 * the display output stays non-empty.
 */
class SleepPhantomNightFallbackTest {

    private val now = 1_800_000_000L                    // "today", unix seconds

    private fun day(d: String, stages: Boolean) = DailyMetric(
        deviceId = "my-whoop", day = d,
        totalSleepMin = if (stages) 420.0 else null,
        deepMin = if (stages) 80.0 else null,
        remMin = if (stages) 90.0 else null,
        lightMin = if (stages) 250.0 else null,
        efficiency = if (stages) 90.0 else null,
    )

    /** THE #940 PHANTOM: a userEdited row whose corrected window is future-dated and whose stages
     *  are the deliberate all-wake fallback. Detected key stays at the real onset this morning. */
    private fun phantom(): SleepSession {
        val detected = now - 5 * 3_600                  // ~01:06 this morning (immutable key)
        val editedStart = now + 16 * 3_600              // tonight 23:00 (the impossible onset)
        val editedEnd = editedStart + 6 * 3_600         // tomorrow 05:00
        return SleepSession(
            deviceId = "my-whoop", startTs = detected, endTs = editedEnd,
            stagesJSON = """[{"start":$editedStart,"end":$editedEnd,"stage":"wake"}]""",
            userEdited = true, startTsAdjusted = editedStart,
        )
    }

    private fun realNight(daysAgo: Long): SleepSession {
        val end = now - daysAgo * 86_400                // woke around "now" that day
        val start = end - 8 * 3_600
        return SleepSession(
            deviceId = "my-whoop", startTs = start, endTs = end,
            stagesJSON = """{"awake":30,"light":250,"deep":80,"rem":90}""",
        )
    }

    /** The defect trigger, pinned: the phantom's day carries no stage minutes in `days`, so the
     *  selected-day model is null. (This is WHY the tab degraded; the fix must survive it.) */
    @Test
    fun phantomSelectedDayModelIsNull() {
        val days = listOf(day("2026-06-30", true), day("2026-07-01", true))
        val night = selectNight(listOf(listOf(phantom())), days, 0)
        assertNotNull(night)
        val n = night!!
        assertNull(buildSleepModel(days, n.session, selectedDay = n.dayKey))
    }

    /** THE FIX: with intact history, the full-history surfaces re-anchor to the newest
     *  stage-bearing day and stay up. Non-empty display output for a non-empty history. */
    @Test
    fun fallbackModelKeepsHistoryVisible() {
        val days = listOf(day("2026-06-29", true), day("2026-06-30", true), day("2026-07-01", true))
        val m = fallbackSleepModel(days)
        assertNotNull("#940 regression: intact history must never render as the empty state", m)
        // The ledger/trend series really carry the history (not a hollow model).
        val resolved = m!!
        assertEquals(3, resolved.trendHours.size)
        assertTrue(resolved.stages.total > 0.0)
    }

    /** Only a history with NO stage-bearing day at all may fall through to the empty state. */
    @Test
    fun trulyEmptyHistoryStillYieldsNull() {
        assertNull(fallbackSleepModel(emptyList()))
        assertNull(fallbackSleepModel(listOf(day("2026-07-01", false))))
    }

    /** The phantom's own day keeps a HERO with a real edit anchor: the user can immediately re-edit
     *  or delete the bad night. `session` is the phantom row itself (its detected key intact). */
    @Test
    fun phantomDayHeroKeepsEditAnchor() {
        val p = phantom()
        val days = listOf(day("2026-06-30", true), day("2026-07-01", true))
        // Newest day = the phantom; older real nights behind it (grouped per day as the screen does).
        val navDays = listOf(listOf(p), listOf(realNight(1)), listOf(realNight(2)))
        val night = selectNight(navDays, days, 0)
        assertNotNull(night)
        assertEquals(p.startTs, night!!.session.startTs)
        // And browsing one day back still resolves the intact real night.
        val previous = selectNight(navDays, days, 1)
        assertNotNull(previous)
        assertEquals(realNight(1).startTs, previous!!.session.startTs)
    }
}
