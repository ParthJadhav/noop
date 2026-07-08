package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * #940 (Android twin of SleepEditGuardTests.swift): the sleep-time editor accepted an impossible bed
 * time. Rolling the bed TIME back across midnight (01:06 -> 23:00) kept the calendar date, so the
 * "corrected" bed landed on the coming evening: a future-dated (here, INVERTED, since Android keeps
 * the wake) night the Sleep tab could not render. These pin the three pure guard rules.
 */
class SleepEditGuardTest {

    private val zone: ZoneId = ZoneId.of("UTC")

    private fun ts(y: Int, mo: Int, d: Int, h: Int, mi: Int): Long =
        LocalDateTime.of(y, mo, d, h, mi).atZone(zone).toEpochSecond()

    // MARK: Rule 1: cross-midnight bed auto-correct

    /** THE #940 SHAPE: night tracked late (bed 01:06, wake 05:00 on 2 Jul), user rolls the bed TIME
     *  back to 23:00 at 05:03 the same morning. The picker kept the date on 2 Jul, so the candidate
     *  is tonight (future, past the wake). The guard snaps it to 1 Jul 23:00: the evening meant. */
    @Test
    fun crossMidnightRollBackDecrementsDate() {
        val corrected = SleepEditGuard.autoCorrectedBed(
            previousBedTs = ts(2026, 7, 2, 1, 6),
            candidateBedTs = ts(2026, 7, 2, 23, 0),
            originalWakeTs = ts(2026, 7, 2, 5, 0),
            nowTs = ts(2026, 7, 2, 5, 3),
            zone = zone,
        )
        assertEquals(ts(2026, 7, 1, 23, 0), corrected)
    }

    /** Same roll made in the EVENING (23:00 today is not future) still decrements: the candidate
     *  sits at/after the night's wake, which is impossible for that night's bed. */
    @Test
    fun pastWakeButNotFutureStillDecrements() {
        val corrected = SleepEditGuard.autoCorrectedBed(
            previousBedTs = ts(2026, 7, 2, 1, 6),
            candidateBedTs = ts(2026, 7, 2, 23, 0),
            originalWakeTs = ts(2026, 7, 2, 5, 0),
            nowTs = ts(2026, 7, 2, 23, 30),
            zone = zone,
        )
        assertEquals(ts(2026, 7, 1, 23, 0), corrected)
    }

    /** MOVE-LATER (the finding's missing case): a user drags a session's bed LATER, past its own wake,
     *  on the SAME day (nap 14:00-15:00 -> bed 16:00 today, wake 15:00 today). The candidate is at/after
     *  the wake but in the PAST, so the old rule shoved it back a full day into a ~23h wrong-day window.
     *  Decrementing here would form an implausible 23h night, so the candidate must be left VERBATIM. */
    @Test
    fun moveLaterPastWakeIsNotDecremented() {
        val candidate = ts(2026, 7, 2, 16, 0)      // rolled LATER, same day, after the 15:00 wake
        val corrected = SleepEditGuard.autoCorrectedBed(
            previousBedTs = ts(2026, 7, 2, 14, 0),
            candidateBedTs = candidate,
            originalWakeTs = ts(2026, 7, 2, 15, 0),
            nowTs = ts(2026, 7, 2, 20, 0),         // evening: 16:00 today is in the past, not future
            zone = zone,
        )
        assertEquals(candidate, corrected)
    }

    /** A normal correction (01:06 -> 00:30, before the wake, in the past) is untouched. */
    @Test
    fun saneEditIsUntouched() {
        val candidate = ts(2026, 7, 2, 0, 30)
        val corrected = SleepEditGuard.autoCorrectedBed(
            previousBedTs = ts(2026, 7, 2, 1, 6),
            candidateBedTs = candidate,
            originalWakeTs = ts(2026, 7, 2, 5, 0),
            nowTs = ts(2026, 7, 2, 6, 45),
            zone = zone,
        )
        assertEquals(candidate, corrected)
    }

    /** A candidate on a DIFFERENT calendar day from the previous value is respected verbatim:
     *  the rule only rescues time-only rolls. */
    @Test
    fun deliberateDateChangeIsRespected() {
        val candidate = ts(2026, 6, 28, 6, 0)
        val corrected = SleepEditGuard.autoCorrectedBed(
            previousBedTs = ts(2026, 7, 2, 1, 6),
            candidateBedTs = candidate,
            originalWakeTs = ts(2026, 7, 2, 5, 0),
            nowTs = ts(2026, 7, 2, 6, 45),
            zone = zone,
        )
        assertEquals(candidate, corrected)
    }

    /** Add-a-nap (no originalWake): only the FUTURE test applies. A nap start after the night's
     *  wake is normal and stays; a future nap start snaps back a day. */
    @Test
    fun napStartOnlyFutureRuleApplies() {
        val now = ts(2026, 7, 2, 18, 0)
        val anchor = ts(2026, 7, 2, 6, 0)
        val pastNap = SleepEditGuard.autoCorrectedBed(anchor, ts(2026, 7, 2, 14, 0), null, now, zone)
        assertEquals(ts(2026, 7, 2, 14, 0), pastNap)
        val futureNap = SleepEditGuard.autoCorrectedBed(anchor, ts(2026, 7, 2, 22, 0), null, now, zone)
        assertEquals(ts(2026, 7, 1, 22, 0), futureNap)
    }

    /** If decrementing a day would STILL be in the future the candidate returns unchanged; the
     *  disjoint confirm and the persistence clamp are the layers behind it. */
    @Test
    fun decrementThatStaysFutureIsNotApplied() {
        val candidate = ts(2026, 7, 5, 23, 0)
        val corrected = SleepEditGuard.autoCorrectedBed(
            previousBedTs = ts(2026, 7, 5, 1, 0),
            candidateBedTs = candidate,
            originalWakeTs = null,
            nowTs = ts(2026, 7, 2, 6, 45),
            zone = zone,
        )
        assertEquals(candidate, corrected)
    }

    // MARK: Rule 2: disjoint-from-coverage detection

    @Test
    fun overlappingWindowIsNotDisjoint() {
        assertFalse(SleepEditGuard.isDisjoint(1_000, 5_000, 2_000, 5_000))
        assertFalse(SleepEditGuard.isDisjoint(2_500, 3_000, 2_000, 5_000))
    }

    @Test
    fun fullyFutureWindowIsDisjoint() {
        assertTrue(SleepEditGuard.isDisjoint(80_000, 100_000, 2_000, 18_000))
    }

    @Test
    fun fullyPastWindowIsDisjoint() {
        assertTrue(SleepEditGuard.isDisjoint(0, 1_000, 2_000, 18_000))
    }

    /** Touching endpoints share no samples: still disjoint (half-open window semantics). */
    @Test
    fun touchingWindowIsDisjoint() {
        assertTrue(SleepEditGuard.isDisjoint(18_000, 20_000, 2_000, 18_000))
        assertTrue(SleepEditGuard.isDisjoint(0, 2_000, 2_000, 18_000))
    }

    /** The Android bed edit keeps the wake, so an un-corrected cross-midnight roll INVERTS the
     *  window (start past the end); that reads as disjoint too and gets stopped. */
    @Test
    fun invertedWindowIsDisjoint() {
        assertTrue(SleepEditGuard.isDisjoint(18_000, 5_000, 2_000, 18_000))
    }

    // MARK: Rule 3: persistence clamp

    @Test
    fun pastWindowPersistsUnchanged() {
        assertEquals(1_000L to 5_000L, SleepEditGuard.clampedEditWindow(1_000, 5_000, nowTs = 10_000))
    }

    @Test
    fun futureEndIsCappedAtNowPlusSlack() {
        assertEquals(1_000L to 10_300L,
            SleepEditGuard.clampedEditWindow(1_000, 50_000, nowTs = 10_000, slackSec = 300))
    }

    @Test
    fun fullyFutureWindowIsRefused() {
        assertNull(SleepEditGuard.clampedEditWindow(80_000, 100_000, nowTs = 10_000))
    }

    @Test
    fun invertedWindowIsRefused() {
        assertNull(SleepEditGuard.clampedEditWindow(5_000, 4_000, nowTs = 10_000))
        assertNull(SleepEditGuard.clampedEditWindow(5_000, 5_000, nowTs = 10_000))
    }
}
