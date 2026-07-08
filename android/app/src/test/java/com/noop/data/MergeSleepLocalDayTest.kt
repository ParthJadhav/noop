package com.noop.data

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Before
import org.junit.Test
import java.util.TimeZone

/**
 * #304 — [WhoopRepository.mergeSleep] keys sleep sessions by the LOCAL wake-day, not UTC. A UTC+ user
 * who wakes early (after local midnight but BEFORE UTC midnight) had their night mis-attributed to
 * yesterday's UTC date, so the dashboard's local "today" read surfaced the previous night.
 *
 * Driven deterministically by pinning the JVM default zone (mergeSleep reads TimeZone.getDefault()).
 * Europe/Moscow is a fixed UTC+3 with no DST, so the offset is stable. Mirrors the Swift resolver/keying
 * intent; the keying itself is also pinned by LocalDayBucketingTest.dayString_eastOfUTC.
 */
class MergeSleepLocalDayTest {

    private val saved: TimeZone = TimeZone.getDefault()

    @Before fun setUtcPlus3() { TimeZone.setDefault(TimeZone.getTimeZone("Europe/Moscow")) } // fixed UTC+3

    @After fun restore() { TimeZone.setDefault(saved) }

    private fun session(startUtc: Long, endUtc: Long) =
        SleepSession(deviceId = "my-whoop-noop", startTs = startUtc, endTs = endUtc)

    /**
     * Two nights, each WAKING at 01:30 LOCAL (UTC+3) on consecutive days, must collapse to two DISTINCT
     * day keys — one per local wake-day. Under the old UTC keying the 01:30-local wake (= 22:30 UTC the
     * previous day) would key to the PRIOR date and two nights could collide on the wrong day.
     */
    @Test
    fun mergeSleep_utcPlus3EarlyWake_producesTwoDistinctDayKeys() {
        // Night A: wakes 2026-06-14 01:30 LOCAL == 2026-06-13 22:30 UTC.
        // Night B: wakes 2026-06-15 01:30 LOCAL == 2026-06-14 22:30 UTC.
        val wakeA = 1_781_389_800L // 2026-06-13 22:30:00 UTC == 2026-06-14 01:30 local
        val wakeB = wakeA + 86_400L // exactly one day later
        val nightA = session(startUtc = wakeA - 6 * 3600L, endUtc = wakeA)
        val nightB = session(startUtc = wakeB - 6 * 3600L, endUtc = wakeB)

        val merged = WhoopRepository.mergeSleep(imported = emptyList(), computed = listOf(nightA, nightB))

        // Both nights survive (distinct local wake-days = distinct dedup keys), not collapsed to one.
        assertEquals("UTC+3 early wakes must key to two distinct local days, not collide", 2, merged.size)
        assertEquals(listOf(wakeA, wakeB), merged.map { it.endTs }.sorted())
    }

    /**
     * #715 — two sessions ending the SAME local day (a main night + a nap) must BOTH survive. The old
     * LinkedHashMap<String, SleepSession> keyed by end-day overwrote on collision and silently dropped
     * one, in the app and the CSV export. Mirrors the Swift WhoopStore.SleepMerge fix (SleepMergeTests).
     */
    @Test
    fun mergeSleep_twoSessionsSameLocalEndDay_bothSurvive() {
        val wake = 1_781_389_800L                                          // 2026-06-14 01:30 local (UTC+3)
        val night = session(startUtc = wake - 6 * 3600L, endUtc = wake)    // ends 01:30 local
        val nap = session(startUtc = wake + 10 * 3600L, endUtc = wake + 11 * 3600L) // ends ~12:30 same local day
        val merged = WhoopRepository.mergeSleep(imported = emptyList(), computed = listOf(night, nap))
        assertEquals("a main night + a nap ending the same local day must both survive", 2, merged.size)
        assertEquals(listOf(night.startTs, nap.startTs).sorted(), merged.map { it.startTs })
    }

    /**
     * The local wake-day key for an 01:30-local (UTC+3) wake is the LOCAL date — the date the dashboard's
     * "today" read uses — not the previous UTC date. This is the exact mis-attribution #304 fixed.
     */
    @Test
    fun mergeSleep_dedupKeyIsLocalWakeDayNotUtc() {
        // 2026-06-14 01:30 local (UTC+3) == 2026-06-13 22:30 UTC.
        val wake = 1_781_389_800L
        val offsetSec = (TimeZone.getDefault().getOffset(wake * 1000) / 1000).toLong()
        // The keyer the fix relies on: local day is 2026-06-14, the UTC day would be 2026-06-13.
        assertEquals("2026-06-14", com.noop.analytics.AnalyticsEngine.dayString(wake, offsetSec))
        assertEquals("2026-06-13", com.noop.analytics.AnalyticsEngine.dayString(wake)) // old UTC behaviour

        // An imported night on that local day wins over a computed night on the SAME local day.
        val imported = session(startUtc = wake - 6 * 3600L, endUtc = wake).copy(efficiency = 95.0)
        val computed = session(startUtc = wake - 7 * 3600L, endUtc = wake - 30 * 60L).copy(efficiency = 80.0)
        val merged = WhoopRepository.mergeSleep(imported = listOf(imported), computed = listOf(computed))
        assertEquals("imported wins on the shared local wake-day", 1, merged.size)
        assertNotNull(merged.first().efficiency)
        assertEquals(95.0, merged.first().efficiency!!, 1e-9)
    }
}
