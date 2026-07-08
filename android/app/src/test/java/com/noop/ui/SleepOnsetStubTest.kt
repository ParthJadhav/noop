package com.noop.ui

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #736 (Android twin of SleepOnsetStubTests.swift): the Sleep tab must not draw the night's hypnogram /
 * bedtime from a spurious BRIEF, sleepless pre-onset awake stub that the gap-bridge folded into the
 * main-night group. [isPreOnsetAwakeStub] is the rule that lets [selectNight] skip such a leading stub so
 * the chart and minutes start at the displayed bedtime (the main block's onset), the same fragment the
 * pencil edits. A genuine first sleep fragment of a biphasic night is NEVER mistaken for a stub (#555).
 */
class SleepOnsetStubTest {

    private fun block(startTs: Long, endTs: Long, stagesJSON: String?): SleepSession =
        SleepSession(deviceId = "dev", startTs = startTs, endTs = endTs, stagesJSON = stagesJSON)

    /** A brief, all-awake leading block (15 min, 0 asleep) IS a spurious pre-onset stub. */
    @Test
    fun briefAllAwakeIsStub() {
        val b = block(0, 15 * 60, """{"awake":15,"light":0,"deep":0,"rem":0}""")
        assertTrue(isPreOnsetAwakeStub(b))
    }

    /** A short block that already holds real sleep (12 min span, 8 asleep) is NOT a stub. */
    @Test
    fun shortButAsleepIsNotStub() {
        val b = block(0, 12 * 60, """{"awake":4,"light":8,"deep":0,"rem":0}""")
        assertFalse(isPreOnsetAwakeStub(b))
    }

    /** THE #736 SHAPE: a LONG all-awake pre-sleep block (the reporter's 21:41-00:27, ~2h45m, 0 asleep) IS a
     *  stub. A multi-hour lie-in before sleep is not part of the night, so it drops off the displayed bedtime. */
    @Test
    fun longAllAwakePreSleepBlockIsStub() {
        val b = block(0, 165 * 60, """{"awake":165,"light":0,"deep":0,"rem":0}""")
        assertTrue(isPreOnsetAwakeStub(b))
    }

    /** A truly absurd all-day awake block (beyond the cap) is NOT silently swallowed. */
    @Test
    fun beyondCapIsNotStub() {
        val b = block(0, 300 * 60, """{"awake":300,"light":0,"deep":0,"rem":0}""")
        assertFalse(isPreOnsetAwakeStub(b))
    }

    /** A block with no parseable stages but within the cap still reads as a (sleepless) stub. */
    @Test
    fun shortWithNoStagesIsStub() {
        val b = block(0, 10 * 60, null)
        assertTrue(isPreOnsetAwakeStub(b))
    }

    /**
     * THE #736 GOLDEN at selectNight level: a three-fragment night — a brief pre-sleep awake stub, then two
     * real sleep fragments split by a short wake (biphasic). The hero's reconstructed segments must start at
     * the FIRST real sleep fragment, never the stub's awake block, so the chart begins at the displayed
     * bedtime. The biphasic split is preserved (both real fragments contribute). The stub stays out of the
     * naps card (it rides in the main-night group).
     */
    @Test
    fun selectNightDropsLeadingStubButKeepsBiphasicNight() {
        // Stub: 21:41-21:55 (14 min), all awake.
        val stubStart = 1_780_000_000L
        val stubEnd = stubStart + 14 * 60
        val stub = block(stubStart, stubEnd,
            """[{"start":$stubStart,"end":$stubEnd,"stage":"wake"}]""")
        // Sleep fragment A ~46 min after the stub (gap < gapBridgeMaxMin so all three bridge), 3h.
        val aStart = stubStart + 60 * 60
        val aEnd = aStart + 3 * 3600
        val fragA = block(aStart, aEnd,
            """[
                {"start":$aStart,"end":${aStart + 3600},"stage":"light"},
                {"start":${aStart + 3600},"end":$aEnd,"stage":"deep"}
            ]""")
        // A brief wake, then sleep fragment B, 4h (the longest → the main block / edit anchor).
        val bStart = aEnd + 20 * 60
        val bEnd = bStart + 4 * 3600
        val fragB = block(bStart, bEnd,
            """[
                {"start":$bStart,"end":${bStart + 2 * 3600},"stage":"light"},
                {"start":${bStart + 2 * 3600},"end":$bEnd,"stage":"rem"}
            ]""")
        val navDays = listOf(listOf(stub, fragA, fragB))

        val hero = selectNight(navDays, emptyList(), 0, habitualMidsleepSec = null)!!
        // The reconstructed group segments start at the first REAL sleep fragment, not the stub's awake block.
        val firstSeg = hero.groupSegments!!.first()
        assertTrue("hero segments must start at real sleep (>= fragment A), not the pre-onset stub",
            firstSeg.start >= aStart)
        // Both real fragments contribute (biphasic night preserved): more than fragment B alone.
        assertTrue("biphasic night must keep both real fragments", hero.groupSegments!!.size >= 4)
        // The stub is not a nap — it stays inside the main-night group.
        assertTrue(hero.napBlocks.none { it.startTs == stubStart })
    }

    /** A genuine single-block night is unchanged: the session is that block. */
    @Test
    fun singleBlockNightUnchanged() {
        val start = 1_780_000_000L
        val end = start + 7 * 3600
        val one = block(start, end,
            """[
                {"start":$start,"end":${start + 3 * 3600},"stage":"light"},
                {"start":${start + 3 * 3600},"end":$end,"stage":"deep"}
            ]""")
        val hero = selectNight(listOf(listOf(one)), emptyList(), 0, habitualMidsleepSec = null)!!
        assertEquals(start, hero.session.effectiveStartTs)
    }
}
