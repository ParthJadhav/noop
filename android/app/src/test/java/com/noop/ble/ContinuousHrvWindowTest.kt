package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #927 Continuous HRV "overnight only" window predicate ([WhoopBleClient.overnightWindowContains]
 * + [WhoopBleClient.continuousHrvStreamWanted]).
 *
 * The window reuses the app's quiet-hours convention byte-for-byte (NotifPrefs.inQuietHours /
 * SedentaryDetector.windowContains): minutes since LOCAL midnight, inclusive start, exclusive end, and
 * the window may wrap across midnight (22:00 → 07:00 by default). The predicate takes the wall-clock
 * minute IN (no date, no epoch), exactly like quiet hours, which is what makes it DST-agnostic: a DST
 * jump moves the wall clock, the window definition never changes, and there is no date arithmetic to
 * disagree with the user's clock. Pure → no Android framework needed; mirrors the Swift
 * ContinuousHrvScheduleTests byte-for-behaviour.
 */
class ContinuousHrvWindowTest {

    /** The quiet-hours defaults the schedule reuses (22:00 → 07:00). */
    private val start = 22 * 60
    private val end = 7 * 60

    // Mode composition (no migration)

    /** Feature off ⇒ never wanted, at any time of day, regardless of the overnight flag. */
    @Test
    fun offMode_neverWants() {
        for (minute in listOf(0, 6 * 60, 12 * 60, 22 * 60, 1439)) {
            assertFalse(WhoopBleClient.continuousHrvStreamWanted(false, false, minute, start, end))
            assertFalse(WhoopBleClient.continuousHrvStreamWanted(false, true, minute, start, end))
        }
    }

    /** ALWAYS mode: continuous on + overnight off ⇒ wanted 24/7. This is what every EXISTING Continuous
     *  HRV user reads with no migration (the new overnight key simply defaults to false), so #927
     *  changes nothing for them. */
    @Test
    fun alwaysMode_wantsAllDay() {
        for (minute in listOf(0, 3 * 60, 6 * 60 + 59, 7 * 60, 12 * 60, 21 * 60 + 59, 22 * 60, 1439)) {
            assertTrue(WhoopBleClient.continuousHrvStreamWanted(true, false, minute, start, end))
        }
    }

    /** OVERNIGHT mode: wanted inside the window, not outside; the daytime half of the day disarms. */
    @Test
    fun overnightMode_gatesOnWindow() {
        assertTrue(WhoopBleClient.continuousHrvStreamWanted(true, true, 23 * 60, start, end))    // 23:00 in
        assertFalse(WhoopBleClient.continuousHrvStreamWanted(true, true, 12 * 60, start, end))   // noon out
    }

    // Window boundaries (quiet-hours semantics, byte-for-byte)

    /** Inclusive start: 22:00 exactly is INSIDE; 21:59 is outside. Matches quiet hours (`now >= start`). */
    @Test
    fun startBoundary_inclusive() {
        assertTrue(WhoopBleClient.overnightWindowContains(22 * 60, start, end))
        assertFalse(WhoopBleClient.overnightWindowContains(21 * 60 + 59, start, end))
    }

    /** Exclusive end: 07:00 exactly is OUTSIDE; 06:59 is inside. Matches quiet hours (`now < end`). */
    @Test
    fun endBoundary_exclusive() {
        assertFalse(WhoopBleClient.overnightWindowContains(7 * 60, start, end))
        assertTrue(WhoopBleClient.overnightWindowContains(6 * 60 + 59, start, end))
    }

    /** The default window wraps midnight: late evening, midnight itself and the small hours are all
     *  inside; midday is outside. (start > end ⇒ `minute >= start || minute < end`.) */
    @Test
    fun wrapAcrossMidnight() {
        assertTrue(WhoopBleClient.overnightWindowContains(23 * 60 + 59, start, end))
        assertTrue(WhoopBleClient.overnightWindowContains(0, start, end))
        assertTrue(WhoopBleClient.overnightWindowContains(3 * 60, start, end))
        assertFalse(WhoopBleClient.overnightWindowContains(12 * 60, start, end))
        assertFalse(WhoopBleClient.overnightWindowContains(15 * 60, start, end))
    }

    /** A non-wrapping window (start <= end) is the plain [start, end) interval: someone who sets their
     *  quiet hours to 01:00 → 05:00 gets exactly that. */
    @Test
    fun nonWrappingWindow() {
        val s = 1 * 60
        val e = 5 * 60
        assertFalse(WhoopBleClient.overnightWindowContains(0, s, e))
        assertFalse(WhoopBleClient.overnightWindowContains(59, s, e))
        assertTrue(WhoopBleClient.overnightWindowContains(60, s, e))          // 01:00 in
        assertTrue(WhoopBleClient.overnightWindowContains(4 * 60 + 59, s, e))
        assertFalse(WhoopBleClient.overnightWindowContains(5 * 60, s, e))     // 05:00 out
        assertFalse(WhoopBleClient.overnightWindowContains(12 * 60, s, e))
    }

    /** start == end is an EMPTY window (the [start, start) convention), never "all day"; byte-for-byte
     *  what the quiet-hours membership does with equal times. */
    @Test
    fun degenerateEqualWindow_isEmpty() {
        val s = 8 * 60
        for (minute in listOf(0, s - 1, s, s + 1, 23 * 60)) {
            assertFalse(WhoopBleClient.overnightWindowContains(minute, s, s))
        }
    }

    /** The extremes of the minute-of-day domain behave: minute 0 (midnight) and 1439 (23:59) resolve
     *  against the wrapped default window without any modular surprises. */
    @Test
    fun minuteDomainExtremes() {
        assertTrue(WhoopBleClient.overnightWindowContains(0, start, end))       // 00:00 in
        assertTrue(WhoopBleClient.overnightWindowContains(1439, start, end))    // 23:59 in
        // And against a daytime window both extremes are out.
        assertFalse(WhoopBleClient.overnightWindowContains(0, 9 * 60, 17 * 60))
        assertFalse(WhoopBleClient.overnightWindowContains(1439, 9 * 60, 17 * 60))
    }
}
