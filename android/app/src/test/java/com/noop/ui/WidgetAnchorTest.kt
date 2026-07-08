package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #911: the SHARED anchor selector both widget producers (the in-app republish in AppViewModel AND the
 * background-service producer in WhoopConnectionService) resolve the widget's day through, so the two
 * can never drift apart around the rollover. Pins the SAME selection the iOS [WidgetAnchorTests] asserts
 * (Swift Repository.widgetAnchor) so the two platforms stay byte-for-byte in agreement: anchor on today's
 * row when scored, else carry the freshest STRICTLY-PRIOR scored day, with the #304 pre-04:00 carve-out
 * and the #547 future-day guard folded in.
 */
class WidgetAnchorTest {

    /** A day row with an optional recovery + optional banked night (the #304 carve-out keys off the
     *  banked night, `totalSleepMin`). */
    private fun day(key: String, recovery: Double?, sleepMin: Double? = null, strain: Double? = null) =
        DailyMetric(
            deviceId = "my-whoop", day = key, recovery = recovery,
            totalSleepMin = sleepMin, strain = strain,
        )

    // (a) today scored -> today's own row.
    @Test
    fun todayScored_anchorsOnTodaysRow() {
        val days = listOf(day("2026-06-18", 72.0), day("2026-06-19", 55.0, strain = 9.0))
        val anchor = widgetAnchorRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")
        assertEquals("2026-06-19", anchor?.day)
        assertEquals(55.0, anchor?.recovery)
    }

    // (b) today unscored, a prior scored day exists -> the freshest STRICTLY-PRIOR scored row.
    @Test
    fun todayUnscored_carriesFreshestPriorScoredDay() {
        val days = listOf(
            day("2026-06-17", 60.0),
            day("2026-06-18", 72.0),
            day("2026-06-19", null), // today, banked but not scored yet
        )
        val anchor = widgetAnchorRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")
        assertEquals("2026-06-18", anchor?.day)
        assertEquals(72.0, anchor?.recovery)
    }

    // (b, cont.) an unscored today row must NOT be echoed as its own anchor.
    @Test
    fun todayUnscoredPartialRow_isNotEchoed() {
        val days = listOf(day("2026-06-18", 72.0), day("2026-06-19", null))
        val anchor = widgetAnchorRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")
        assertEquals("2026-06-18", anchor?.day)
    }

    // (c) #304 pre-04:00 carve-out: local calendar day differs from the logical day. resolveTodayRow
    // prefers the LOCAL banked row, so the anchor's carriedKey is that local row's own day and a same-day
    // later-scored row is NOT resurfaced past it.
    @Test
    fun pre0400CarveOut_prefersLocalBankedRow_notASameDayLaterRow() {
        val days = listOf(
            day("2026-06-16", 60.0),
            day("2026-06-17", 71.0),                    // yesterday, scored
            day("2026-06-18", null, sleepMin = 430.0),  // local banked night, unscored = today
        )
        val anchor = widgetAnchorRow(days, logicalKey = "2026-06-17", localKey = "2026-06-18")
        // today (the local 18th row) is unscored, so carriedKey == "2026-06-18" and the freshest
        // STRICTLY-PRIOR scored day (the 17th) carries over, NOT re-echoing the local row or the 16th.
        assertEquals("2026-06-17", anchor?.day)
        assertEquals(71.0, anchor?.recovery)
    }

    @Test
    fun pre0400CarveOut_localBankedRowScored_isItsOwnAnchor() {
        val days = listOf(
            day("2026-06-17", 71.0),
            day("2026-06-18", 66.0, sleepMin = 430.0),
        )
        val anchor = widgetAnchorRow(days, logicalKey = "2026-06-17", localKey = "2026-06-18")
        assertEquals("2026-06-18", anchor?.day)
        assertEquals(66.0, anchor?.recovery)
    }

    // (d) a future-dated row (#547) is never selected as the anchor.
    @Test
    fun neverAnchorsAFutureDatedRow() {
        val days = listOf(
            day("2026-06-17", 60.0),
            day("2026-06-18", 72.0),
            day("2026-06-19", null),  // today, unscored
            day("2026-07-12", 80.0),  // stray future row
        )
        val anchor = widgetAnchorRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")
        assertEquals("2026-06-18", anchor?.day)
        assertEquals(72.0, anchor?.recovery)
    }

    @Test
    fun futureOnlyBesidesToday_returnsNull() {
        val days = listOf(
            day("2026-06-19", null),  // today, unscored
            day("2026-07-12", 80.0),  // future-only
        )
        assertNull(widgetAnchorRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19"))
    }

    // (e) no data -> null (blank widget, no crash).
    @Test
    fun noData_returnsNull() {
        assertNull(widgetAnchorRow(emptyList(), logicalKey = "2026-06-19", localKey = "2026-06-19"))
    }

    @Test
    fun noPriorEverScored_returnsNull() {
        val days = listOf(day("2026-06-18", null), day("2026-06-19", null))
        assertNull(widgetAnchorRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19"))
    }
}
