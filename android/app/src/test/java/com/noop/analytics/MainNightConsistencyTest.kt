package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #525 — sleep numbers must agree across screens. A day can hold an overnight AND a daytime nap; the
 * day's canonical sleep total must be the MAIN night (the same block the Sleep tab's hero shows),
 * never the night + nap SUM. Naps stay their own session rows, labelled separately.
 *
 * Faithful Kotlin mirror of the #525 cases in SleepStageTotalsTests.swift / AnalyticsEngineTests.swift:
 * same selection rule (overnight-preferring, then longest), same fixtures, same invariant.
 */
class MainNightConsistencyTest {

    /** An arbitrary fixed UTC midnight (ref % 86400 == 0). tzOffset 0 → local == UTC. */
    private val refMidnight = 1_749_513_600L
    private fun atHour(hourUTC: Int): Long = refMidnight + hourUTC * 3_600L
    private fun atMin(hour: Int, min: Int): Long = refMidnight + hour * 3_600L + min * 60L
    /** Local time-of-day "HH:mm" → seconds. */
    private fun sod(hour: Int, min: Int): Long = hour * 3_600L + min * 60L

    // ── main-night selection (the single shared rule) ────────────────────────────────────────────

    @Test
    fun mainNightPrefersOvernightOverLongerDaytimeNap() {
        val nightStart = atHour(23) - 86_400L  // 2026-06-09 23:00 overnight onset
        val napStart = atHour(13)              // 13:00 daytime onset
        // The nap is LONGER in clock span, but the overnight block must still win.
        val blocks = listOf(
            SleepStageTotals.NightBlock(napStart, napStart + 5 * 3600),    // 5h daytime
            SleepStageTotals.NightBlock(nightStart, nightStart + 4 * 3600), // 4h overnight
        )
        assertEquals(1, SleepStageTotals.mainNightIndex(blocks, 0L))
    }

    @Test
    fun mainNightLongestAmongOvernightBlocks() {
        val a = atHour(22) - 86_400L
        val b = atHour(23) - 86_400L + 1_800L
        val blocks = listOf(
            SleepStageTotals.NightBlock(a, a + 3 * 3600),  // 3h
            SleepStageTotals.NightBlock(b, b + 6 * 3600),  // 6h longer overnight wins
        )
        assertEquals(1, SleepStageTotals.mainNightIndex(blocks, 0L))
    }

    /** #555 regression: a biphasic / briefly-interrupted main night (fragments split by short wakes)
     *  resolves to ONE bridged GROUP containing ALL its fragments, while a distant afternoon nap stays
     *  OUTSIDE it. The Sleep tab classifies naps as "not in this group" and aggregates the group for the
     *  hero, so the bridged siblings are no longer rendered as phantom naps ("three naps instead of a
     *  continuous sleep"). Mirrors Swift testBiphasicNightGroupsAllFragmentsAndExcludesNap. */
    @Test
    fun biphasicNightGroupsAllFragmentsAndExcludesNap() {
        val f1 = atHour(23) - 86_400L          // 23:00–01:00
        val f2 = atMin(1, 40)                  // 01:40–04:00 (40 min gap → bridges)
        val f3 = atMin(4, 30)                  // 04:30–07:00 (30 min gap → bridges)
        val nap = atHour(14)                   // 14:00–15:00 (7 h gap → does NOT bridge)
        val blocks = listOf(
            SleepStageTotals.NightBlock(f1, f1 + 2 * 3600),
            SleepStageTotals.NightBlock(f2, f2 + 140 * 60),
            SleepStageTotals.NightBlock(f3, f3 + 150 * 60),
            SleepStageTotals.NightBlock(nap, nap + 3600),
        )
        assertEquals(
            "all three bridged night fragments are the main group; the afternoon nap is excluded",
            listOf(0, 1, 2), SleepStageTotals.mainNightGroupIndices(blocks, 0L),
        )
        val single = SleepStageTotals.mainNightIndex(blocks, 0L)
        assertNotNull(single)
        assertTrue("the bare winner is one of the night fragments, never the nap", single!! in listOf(0, 1, 2))
        assertTrue(
            "the afternoon nap is never in the main-night group",
            SleepStageTotals.mainNightGroupIndices(blocks, 0L)?.contains(3) == false,
        )
    }

    @Test
    fun mainNightEmptyAndTieAreDeterministic() {
        assertNull(SleepStageTotals.mainNightIndex(emptyList(), 0L))
        // Two SCORE-TIED blocks (equal duration AND equal circular distance to the cold-start anchor,
        // mirrored either side of 03:30) → the EARLIER onset breaks the tie (stable across platforms).
        // early: 00:30 onset, 4h → mid 02:30 (1h before 03:30). late: 02:30 onset, 4h → mid 04:30 (1h after).
        val early = atMin(0, 30)
        val late = atMin(2, 30)
        val blocks = listOf(
            SleepStageTotals.NightBlock(late, late + 4 * 3600),
            SleepStageTotals.NightBlock(early, early + 4 * 3600),
        )
        assertEquals(1, SleepStageTotals.mainNightIndex(blocks, 0L))
    }

    // ── the #525 seam invariant: total == main night, not the sum ────────────────────────────────

    @Test
    fun overnightPlusNapReportsConsistentTotalsNotTheSum() {
        val nightStart = atHour(23) - 86_400L
        val napStart = atHour(14)
        val nightStages = """{"awake":24,"light":214,"deep":82,"rem":96}""" // 392 min asleep
        val napStages = """{"awake":2,"light":30,"deep":10,"rem":8}"""       // 48 min asleep

        val mainOnly = SleepStageTotals.dailyAggregate(listOf(nightStages))!!
        assertEquals(392.0, mainOnly.totalSleepMin, 1e-6)

        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(nightStart to nightStages, napStart to napStages),
            edited = emptyMap(),
            onsetByStart = mapOf(nightStart to nightStart, napStart to napStart),
            offsetSec = 0L,
        )
        assertNotNull(r)
        assertEquals("day total = MAIN night, not night+nap sum", mainOnly.totalSleepMin, r!!.sleep.totalSleepMin, 1e-6)
        assertEquals(mainOnly.deepMin, r.sleep.deepMin, 1e-6)
        assertEquals(mainOnly.remMin, r.sleep.remMin, 1e-6)
        assertNotEquals("must NOT sum the nap in", 440.0, r.sleep.totalSleepMin, 1e-6)
    }

    @Test
    fun honoringEditsMainNightModeTracksEditedNightNotNapSum() {
        val nightStart = atHour(23) - 86_400L
        val napStart = atHour(14)
        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(
                nightStart to """{"awake":24,"light":214,"deep":82,"rem":96}""",
                napStart to """{"awake":2,"light":30,"deep":10,"rem":8}""",
            ),
            edited = mapOf(nightStart to """{"awake":0,"light":118,"deep":82,"rem":96}"""), // trimmed to 296
            onsetByStart = mapOf(nightStart to nightStart, napStart to napStart),
            offsetSec = 0L,
        )
        assertNotNull(r)
        assertTrue(r!!.editApplied)
        assertEquals("tracks the EDITED main night, nap excluded", 296.0, r.sleep.totalSleepMin, 1e-6)
    }

    @Test
    fun honoringEditsLegacySumWhenNoOnsets() {
        // With NO onsets the seam keeps the legacy sum-of-all-blocks total (older callers unchanged).
        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(
                100L to """{"awake":2,"light":30,"deep":10,"rem":8}""",
                1000L to """{"awake":24,"light":214,"deep":82,"rem":96}""",
            ),
            edited = emptyMap(),
        )
        assertNotNull(r)
        assertEquals(48.0 + 392.0, r!!.sleep.totalSleepMin, 1e-6)
    }

    // The end-to-end analyzeDay variant (overnight + synthetic daytime nap, asserting 2 detected) was
    // dropped on both platforms: it leaned on the SleepStager detecting a synthetic nap, which the
    // daytime-false-sleep guard rejects by design, so it tested detection (a #508 concern), not #525's
    // aggregation. The seam tests above cover the main-night-not-sum reconciliation deterministically.

    // ── #777/#705 inter-fragment awake (out-of-bed gap between bridged fragments) ────────────────────

    /** The shared definition: sum only the POSITIVE gaps between consecutive (start,end) spans, sorted by
     *  start. Abutting / overlapping fragments contribute 0; an unsorted input is sorted first. Mirrors
     *  Swift testInterFragmentAwakeSecondsSumsPositiveGapsOnly. */
    @Test
    fun interFragmentAwakeSecondsSumsPositiveGapsOnly() {
        val f1 = 0L to 6 * 3600L
        val f2 = (6 * 3600L + 20 * 60L) to 9 * 3600L
        assertEquals((20 * 60).toDouble(), SleepStageTotals.interFragmentAwakeSeconds(listOf(f1, f2)), 1e-6)
        // Order-independent.
        assertEquals((20 * 60).toDouble(), SleepStageTotals.interFragmentAwakeSeconds(listOf(f2, f1)), 1e-6)
        // Abutting / single → 0.
        assertEquals(0.0, SleepStageTotals.interFragmentAwakeSeconds(listOf(0L to 100L, 100L to 200L)), 1e-6)
        assertEquals(0.0, SleepStageTotals.interFragmentAwakeSeconds(listOf(0L to 100L)), 1e-6)
        // Two gaps across three fragments sum (60s + 40s = 100s).
        val three = listOf(0L to 100L, 160L to 300L, 340L to 500L)
        assertEquals(100.0, SleepStageTotals.interFragmentAwakeSeconds(three), 1e-6)
    }

    /** #777/#705 regression fixture: a main night bridged from two fragments split by a 20-min OUT-OF-BED
     *  gap reports ~20 min AWAKE on the day's rollup (it read as ~0 before). The seam folds the gap into
     *  AWAKE via the in-bed denominator with NO double-count. Mirrors Swift
     *  testHonoringEditsFragmentedNightCountsGapAsAwake. */
    @Test
    fun honoringEditsFragmentedNightCountsGapAsAwake() {
        val f1Start = atHour(23) - 86_400L          // 23:00 onset, 180 min span
        val f2Start = atMin(2, 20)                  // 02:20 onset → 20-min gap after f1's 02:00 end
        val f1Stages = """{"awake":0,"light":120,"deep":30,"rem":30}""" // 180 asleep, 180 in-bed
        val f2Stages = """{"awake":0,"light":140,"deep":40,"rem":40}""" // 220 asleep, 220 in-bed

        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(f1Start to f1Stages, f2Start to f2Stages),
            edited = emptyMap(),
            onsetByStart = mapOf(f1Start to f1Start, f2Start to f2Start),
            offsetSec = 0L,
        )
        assertNotNull(r)
        assertFalse(r!!.editApplied)
        // Asleep is the SUM of the two fragments (400 min); the gap is awake, not sleep.
        assertEquals("asleep is the sum of both fragments", 400.0, r.sleep.totalSleepMin, 1e-6)
        // In-bed = 180 + 220 + 20 (gap) = 420 min. Awake = in-bed − asleep = 20 min (the gap), NOT ~0.
        val awakeMin = r.sleep.totalSleepMin / r.sleep.efficiency - r.sleep.totalSleepMin
        assertEquals("the 20-min out-of-bed gap reads as ~20 min awake (#777)", 20.0, awakeMin, 0.01)
        assertEquals("efficiency reflects the gap", 400.0 / 420.0, r.sleep.efficiency, 1e-4)
    }

    /** The seam definition and the standalone aggregate agree to the minute (no double-count): feeding the
     *  SAME gap to dailyAggregate(_, interFragmentAwakeSeconds) yields the identical in-bed/awake the seam
     *  reports. A zero gap reproduces the legacy behaviour exactly. Mirrors Swift
     *  testInterFragmentAwakeFoldsConsistentlyNoDoubleCount. */
    @Test
    fun interFragmentAwakeFoldsConsistentlyNoDoubleCount() {
        val f1 = """{"awake":0,"light":120,"deep":30,"rem":30}""" // 180 asleep
        val f2 = """{"awake":0,"light":140,"deep":40,"rem":40}""" // 220 asleep
        val agg = SleepStageTotals.dailyAggregate(listOf(f1, f2), (20 * 60).toDouble())!!
        assertEquals(400.0, agg.totalSleepMin, 1e-6)
        assertEquals(400.0 / 420.0, agg.efficiency, 1e-4)
        val legacy = SleepStageTotals.dailyAggregate(listOf(f1, f2))!!
        val folded0 = SleepStageTotals.dailyAggregate(listOf(f1, f2), 0.0)!!
        assertEquals(legacy.efficiency, folded0.efficiency, 1e-12)
    }

    // ── #547 learned-timing scored selector (the gate is gone) ───────────────────────────────────

    /** THE pikapik case: a genuinely LONG sleep whose onset is in the daytime gap [10:00, 20:00) beats a
     *  SHORT overnight fragment. The old hard gate always picked the fragment; the score lets duration win. */
    @Test
    fun longDaytimeOnsetBeatsShortOvernightFragment() {
        val dayLong = atHour(11)               // daytime-gap onset, 7h
        val nightFrag = atHour(23) - 86_400L   // overnight onset, only 1.5h
        val blocks = listOf(
            SleepStageTotals.NightBlock(dayLong, dayLong + 7 * 3600),       // 420 + ~0 bonus
            SleepStageTotals.NightBlock(nightFrag, nightFrag + 90 * 60),    // 90 + up-to-90 bonus
        )
        assertEquals("7h daytime sleep outscores a 1.5h overnight fragment", 0,
            SleepStageTotals.mainNightIndex(blocks, 0L))
    }

    /** The reconciled window: a 10:30 onset is overnight under [20:00,11:00) (off-by-one fixed), so it no
     *  longer disagrees with the detector. Equal-duration far-from-anchor blocks tie on score → earlier wins. */
    @Test
    fun tenThirtyOnsetIsTreatedAsOvernightNotDaytime() {
        assertTrue(SleepStageTotals.isOvernightOnset(atMin(10, 30), 0L))
        val early = atMin(10, 30)  // 3h, mid 12:00
        val nap = atHour(15)       // 3h, mid 16:30 (both beyond the 5h bonus zero → bonus 0)
        val blocks = listOf(
            SleepStageTotals.NightBlock(nap, nap + 3 * 3600),
            SleepStageTotals.NightBlock(early, early + 3 * 3600),
        )
        assertEquals("score tie → earlier onset; the [10,11) boundary no longer disagrees", 1,
            SleepStageTotals.mainNightIndex(blocks, 0L))
    }

    /** A late/shift sleeper: a 14:00 habitual midsleep makes a daytime sleep the MAIN block. */
    @Test
    fun habitualMidsleepShiftsThePickForADaytimeSleeper() {
        val habitual = sod(14, 0)
        val dayBlock = atHour(11)             // 6h daytime, mid 14:00 (on the habitual)
        val nightBlock = atHour(23) - 86_400L // 6h overnight, mid 02:00
        val blocks = listOf(
            SleepStageTotals.NightBlock(nightBlock, nightBlock + 6 * 3600),
            SleepStageTotals.NightBlock(dayBlock, dayBlock + 6 * 3600),
        )
        assertEquals("with a 14:00 habitual midsleep the daytime sleep is main", 1,
            SleepStageTotals.mainNightIndex(blocks, 0L, habitual))
        assertEquals("cold-start band still favors the overnight block", 0,
            SleepStageTotals.mainNightIndex(blocks, 0L))
    }

    /** #518 intent preserved via TIMING, not a gate: a 4h habitual-night block beats a 5h afternoon block. */
    @Test
    fun habitualAlignedShorterNightBeatsLongerAfternoon() {
        val habitual = sod(3, 0)
        val afternoon = atHour(13)  // 5h = 300, mid 15:30, bonus 0
        val night = atHour(1)       // 4h = 240, mid 03:00, bonus 90 → 330
        val blocks = listOf(
            SleepStageTotals.NightBlock(afternoon, afternoon + 5 * 3600),
            SleepStageTotals.NightBlock(night, night + 4 * 3600),
        )
        assertEquals("habitual-aligned 4h night beats a 5h afternoon (timing, not a hard floor)", 1,
            SleepStageTotals.mainNightIndex(blocks, 0L, habitual))
    }

    // ── #518 invariant (R1): a realistic daytime nap can NEVER out-rank the real night ───────────────

    // After the #547 gate removal the invariant "a nap can't out-rank the real night" is protected ONLY
    // by the +90 min alignment margin (score = asleepMinutes + bonus, bonus in [0, 90]). A non-main block
    // out-scores the night iff its asleep duration exceeds the night's by MORE than (night_bonus −
    // nap_bonus) <= 90. Cold-start anchor 03:30: a real >=4h night scores >=240; a TRUE daytime doze
    // (onset >=06:00, <=180 min) tops out at 210, so the night ALWAYS wins. Under a night-time learned
    // habitual the margin is larger still (night +90, far-off nap +0). Mirrors the Swift R1 pins.

    /** A realistic daytime nap (20–180 min) can NEVER beat a real 4h+ night, COLD-START. Exhaustive
     *  sweep over the realistic ranges; the night (index 1) must always be the pick. */
    @Test
    fun realisticNapNeverBeatsRealNightColdStart() {
        // night: 4h..9h, onset 20:00..01:00 (prev-evening via -86400). nap: 20..180 min, onset 06:00..21:00.
        val nightStarts = listOf(atHour(20) - 86_400L, atHour(22) - 86_400L, atHour(23) - 86_400L,
            atHour(0), atHour(1))
        val nightHours = listOf(4, 5, 6, 7, 8, 9)
        val napStarts = listOf(atHour(6), atHour(8), atHour(10), atHour(12), atHour(13), atHour(15),
            atHour(17), atHour(19), atHour(21))
        val napMins = listOf(20, 30, 45, 60, 90, 120, 150, 180)
        for (nStart in nightStarts) for (nh in nightHours) for (pStart in napStarts) for (pm in napMins) {
            val blocks = listOf(
                SleepStageTotals.NightBlock(pStart, pStart + pm * 60L),
                SleepStageTotals.NightBlock(nStart, nStart + nh * 3600L),
            )
            assertEquals(
                "cold-start: a ${pm}min nap must NOT out-rank a ${nh}h night",
                1, SleepStageTotals.mainNightIndex(blocks, 0L),
            )
        }
    }

    /** Same pin, LEARNED-TIMING (habitual 03:00): the night earns the full +90 and a daytime nap earns 0
     *  (>5h circular away), so the night wins by an even larger margin. */
    @Test
    fun realisticNapNeverBeatsRealNightLearnedTiming() {
        val habitual = sod(3, 0)
        val nightStarts = listOf(atHour(22) - 86_400L, atHour(23) - 86_400L, atHour(0), atHour(1))
        val nightHours = listOf(4, 5, 6, 7, 8)
        val napStarts = listOf(atHour(10), atHour(12), atHour(13), atHour(15), atHour(17), atHour(19))
        val napMins = listOf(20, 45, 60, 90, 120, 150, 180)
        for (nStart in nightStarts) for (nh in nightHours) for (pStart in napStarts) for (pm in napMins) {
            val blocks = listOf(
                SleepStageTotals.NightBlock(pStart, pStart + pm * 60L),
                SleepStageTotals.NightBlock(nStart, nStart + nh * 3600L),
            )
            assertEquals(
                "learned: a ${pm}min nap must NOT out-rank a ${nh}h night",
                1, SleepStageTotals.mainNightIndex(blocks, 0L, habitual),
            )
        }
    }

    /** The tightest cold-start margin: a 4h night onset 20:00 (mid 22:00, bonus 0 → 240) vs the single
     *  most-favourable TRUE-daytime doze (onset 06:00, 180 min, mid 07:30, bonus 30 → 210). Night wins by
     *  30 — the worst case in the realistic range. Pin it so any future bonus change that erodes the
     *  margin trips this test. */
    @Test
    fun tightestColdStartMarginNightStillWins() {
        val night = atHour(20) - 86_400L   // 4h, mid 22:00 → bonus 0 → 240
        val bestNap = atHour(6)            // 180min, mid 07:30 → bonus 30 → 210
        val blocks = listOf(
            SleepStageTotals.NightBlock(bestNap, bestNap + 180 * 60L),
            SleepStageTotals.NightBlock(night, night + 4 * 3600L),
        )
        assertEquals("worst-case realistic doze (210) still loses to a barely-timed 4h night (240)",
            1, SleepStageTotals.mainNightIndex(blocks, 0L))
    }

    /** The genuinely-ambiguous case is NOT a regression and is DEFENSIBLE: a short 4h night + a LONG 6h
     *  daytime sleep → the 6h block is main (longest qualifying wins, per the research). The user can edit
     *  and the guidance layer explains it. Pins the INTENTIONAL behaviour so a future "harden the night"
     *  change can't silently flip it back to the short night. */
    @Test
    fun ambiguousLongDaytimeSleepBeatsShortNightByDesign() {
        val night = atHour(23) - 86_400L   // 4h overnight = 240, mid 01:00, cold-start bonus 75 → 315
        val dayLong = atHour(12)           // 6h daytime  = 360, mid 15:00, bonus 0 → 360
        val blocks = listOf(
            SleepStageTotals.NightBlock(night, night + 4 * 3600L),
            SleepStageTotals.NightBlock(dayLong, dayLong + 6 * 3600L),
        )
        assertEquals(
            "a 6h daytime sleep (360) beats a 4h night even WITH its bonus (315) — longest wins, by design",
            1, SleepStageTotals.mainNightIndex(blocks, 0L),
        )
    }

    /** Nap-only day (NO hard duration floor): a lone short nap still resolves to a main block. */
    @Test
    fun napOnlyDayResolvesToTheNapAsMain() {
        val nap = atHour(13)  // 40 min daytime nap, the only block
        assertEquals(0, SleepStageTotals.mainNightIndex(
            listOf(SleepStageTotals.NightBlock(nap, nap + 40 * 60)), 0L))
        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(nap to """{"awake":2,"light":24,"deep":8,"rem":6}"""),
            edited = emptyMap(),
            onsetByStart = mapOf(nap to nap), offsetSec = 0L,
        )
        assertNotNull(r)
        assertEquals("nap-only day reports the nap's sleep", 38.0, r!!.sleep.totalSleepMin, 1e-6)
    }

    /** Biphasic / bridged night: two runs separated by a < 60 min wake are one block for selection. */
    @Test
    fun gapBridgeMergesShortWakeSplitNight() {
        val a = atHour(23) - 86_400L           // 3h
        val bStart = a + 3 * 3600 + 30 * 60    // 30 min wake gap (< 60) then resume 3h
        val bridged = SleepStageTotals.bridgeAdjacent(listOf(
            SleepStageTotals.NightBlock(a, a + 3 * 3600),
            SleepStageTotals.NightBlock(bStart, bStart + 3 * 3600),
        ))
        assertEquals("a < 60 min wake gap bridges the two runs", 1, bridged.size)
        assertEquals(a, bridged[0].start)
        assertEquals(bStart + 3 * 3600, bridged[0].end)
        val cStart = a + 3 * 3600 + 75 * 60
        val unbridged = SleepStageTotals.bridgeAdjacent(listOf(
            SleepStageTotals.NightBlock(a, a + 3 * 3600),
            SleepStageTotals.NightBlock(cStart, cStart + 3 * 3600),
        ))
        assertEquals("a >= 60 min wake gap stays two blocks", 2, unbridged.size)
    }

    /** Cross-midnight onset: a 23:30 onset is overnight and its midpoint math wraps correctly. */
    @Test
    fun crossMidnightOnsetScoresAsNight() {
        val night = atMin(23, 30) - 86_400L  // 6h crossing midnight, mid 02:30
        val nap = atHour(13)                 // 1h
        val blocks = listOf(
            SleepStageTotals.NightBlock(nap, nap + 1 * 3600),
            SleepStageTotals.NightBlock(night, night + 6 * 3600),
        )
        assertEquals(1, SleepStageTotals.mainNightIndex(blocks, 0L))
    }

    /** Circular-time correctness: 23:30 and 00:30 are an HOUR apart, not 23h. */
    @Test
    fun circularDistanceWrapsMidnight() {
        assertEquals(3600L, SleepStageTotals.circularDistanceSec(sod(23, 30), sod(0, 30)))
        assertEquals(3600L, SleepStageTotals.circularDistanceSec(sod(0, 30), sod(23, 30)))
        assertEquals(43200L, SleepStageTotals.circularDistanceSec(sod(12, 0), sod(0, 0)))
        assertEquals(0L, SleepStageTotals.circularDistanceSec(sod(3, 30), sod(3, 30)))
    }

    // ── #547 habitual midsleep (learned timing) ──────────────────────────────────────────────────

    /** Cold-start: fewer than minDays of history → null (the scorer then uses the overnight band). */
    @Test
    fun habitualMidsleepNullOnColdStart() {
        val hist = (0 until 5).map { d ->
            val onset = atHour(23) - 86_400L + d * 86_400L
            SleepStageTotals.HistoryBlock(onset, onset + 7 * 3600, "day-$d")
        }
        assertNull(SleepStageTotals.habitualMidsleepSec(hist, 0L))
    }

    /** A regular sleeper: 20 nights at 23:00→06:00 (mid 02:30) → habitual midsleep == 02:30. Each night
     *  shares its day key with a short same-day nap; longest-per-day picks the night. */
    @Test
    fun habitualMidsleepLearnsRegularTiming() {
        val hist = ArrayList<SleepStageTotals.HistoryBlock>()
        for (d in 0 until 20) {
            val onset = atHour(23) - 86_400L + d * 86_400L
            val key = "night-$d"
            hist.add(SleepStageTotals.HistoryBlock(onset, onset + 7 * 3600, key))         // 7h night
            val napOnset = onset - 8 * 3600                                               // a 15:00 nap
            hist.add(SleepStageTotals.HistoryBlock(napOnset, napOnset + 1 * 3600, key))   // 1h nap, same key
        }
        val mid = SleepStageTotals.habitualMidsleepSec(hist, 0L)
        assertNotNull(mid)
        assertEquals("midsleep is the night's midpoint, naps excluded", sod(2, 30), mid!!)
    }

    /** Circular learning across midnight: mids at 23:30 and 00:30 average to ~midnight, not noon. */
    @Test
    fun habitualMidsleepCircularAcrossMidnight() {
        val hist = ArrayList<SleepStageTotals.HistoryBlock>()
        for (d in 0 until 16) {
            // even d → onset 20:00 (7h → mid 23:30); odd d → onset 21:00 (7h → mid 00:30).
            val baseOnset = if (d % 2 == 0) atHour(20) - 86_400L else atHour(21) - 86_400L
            val onset = baseOnset + d * 86_400L
            hist.add(SleepStageTotals.HistoryBlock(onset, onset + 7 * 3600, "day-$d"))
        }
        val mid = SleepStageTotals.habitualMidsleepSec(hist, 0L)
        assertNotNull(mid)
        val dist = SleepStageTotals.circularDistanceSec(mid!!, sod(0, 0))
        assertTrue("circular mean of 23:30/00:30 ≈ midnight, not noon", dist < 120L)
    }

    // ── #547 Caveat A: the UI selector and the engine selector agree for a SHIFT sleeper ───────────

    /** THE bug this fix closes: a shift/late sleeper whose LEARNED habitual midsleep is ~15:00. On a day
     *  with BOTH an afternoon main sleep AND a shorter overnight block, the engine (which threads the
     *  learned habitual into `analyzeDay`) tracked the AFTERNOON block, but the Sleep tab hero — which used
     *  to call the selector with NO habitual (cold-start band only) — picked the OVERNIGHT block, breaking
     *  the #525/#547 "hero == analytics total" invariant for that user.
     *
     *  This replays both seams over the EXACT same blocks: (1) the LEARNED habitual is computed from this
     *  shift-sleeper's history via the same `habitualMidsleepSec` pure function the engine and the new
     *  `WhoopRepository.habitualMidsleepSec` both use; (2) `mainNightIndex(..., habitualMidsleepSec)` — the
     *  single shared selector both `mainSleepBlock` (UI, now fed the learned habitual) and `analyzeDay`
     *  (engine) call — resolves to the SAME index. With the fix the UI passes the learned habitual, so it
     *  picks the AFTERNOON block, matching the engine; the asserted contrast is the OLD cold-start UI call
     *  (null habitual) picking the overnight block — the divergence the fix removes. Mirrors Swift. */
    @Test
    fun shiftSleeperUIAndEngineSelectorPickSameAfternoonBlock() {
        // 1) Learn the habitual from 20 afternoon nights (onset 12:00, 6h → mid 15:00). Distinct day keys.
        val hist = ArrayList<SleepStageTotals.HistoryBlock>()
        for (d in 0 until 20) {
            val onset = atHour(12) + d * 86_400L
            hist.add(SleepStageTotals.HistoryBlock(onset, onset + 6 * 3600, "day-$d"))
        }
        val habitual = SleepStageTotals.habitualMidsleepSec(hist, 0L)
        assertNotNull("20 afternoon nights clear the cold-start threshold", habitual)
        assertTrue("learned midsleep is ~15:00 for this shift sleeper",
            SleepStageTotals.circularDistanceSec(habitual!!, sod(15, 0)) < 120L)

        // 2) A target day with BOTH an afternoon main sleep (mid ~15:00, on the habitual) AND a shorter
        //    overnight block. Index 0 = overnight, index 1 = afternoon (input order is irrelevant).
        val overnight = atHour(23) - 86_400L          // 5h overnight, mid ~01:30 (far from 15:00)
        val afternoon = atHour(12)                    // 6h afternoon, mid 15:00 (on the habitual)
        val blocks = listOf(
            SleepStageTotals.NightBlock(overnight, overnight + 5 * 3600),
            SleepStageTotals.NightBlock(afternoon, afternoon + 6 * 3600),
        )

        // The shared selector WITH the learned habitual (what BOTH the UI hero AND the engine now use).
        val withHabitual = SleepStageTotals.mainNightIndex(blocks, 0L, habitual)
        assertEquals("with the learned ~15:00 habitual, the afternoon block is main (engine + UI agree)",
            1, withHabitual)

        // The OLD cold-start UI call (null habitual) diverged — it picked the overnight block. This is the
        // exact bug Caveat A removes by feeding the same learned habitual to the UI selector.
        val coldStart = SleepStageTotals.mainNightIndex(blocks, 0L)
        assertEquals("cold-start band picks the overnight block — the pre-fix UI/engine divergence",
            0, coldStart)
        assertNotEquals("the learned habitual is exactly what makes the UI agree with the engine",
            withHabitual, coldStart)
    }

    // ── #547 Caveat B: circularMeanSec degenerate-vector guard ────────────────────────────────────

    /** Antipodal midpoints (12h apart) have a near-zero resultant vector, so `atan2` returns a meaningless
     *  (and potentially cross-platform-divergent) direction. The guard returns null so `habitualMidsleepSec`
     *  falls back to cold-start rather than emit a bogus anchor. Here: 8 midpoints at 00:00 + 8 at 12:00. */
    @Test
    fun circularMeanReturnsNullForAntipodalMidpoints() {
        val secs = (0 until 8).flatMap { listOf(sod(0, 0), sod(12, 0)) }   // 16 values, perfectly antipodal
        assertNull("antipodal midpoints → degenerate resultant → null (no meaningless angle)",
            SleepStageTotals.circularMeanSec(secs))
    }

    /** The guard also fires end-to-end: a 16-day history split evenly between two antipodal sleep times
     *  (per-day midpoints 12h apart) clears the day-count threshold but yields null, NOT a bogus
     *  midnight/noon anchor — so the scorer falls back to the cold-start band identically on both platforms. */
    @Test
    fun habitualMidsleepNullWhenLearnedTimingIsAntipodal() {
        val hist = ArrayList<SleepStageTotals.HistoryBlock>()
        for (d in 0 until 16) {
            // even d → onset 20:30 (7h → mid 00:00); odd d → onset 08:30 (7h → mid 12:00). Distinct keys.
            val baseOnset = if (d % 2 == 0) atMin(20, 30) - 86_400L else atMin(8, 30)
            val onset = baseOnset + d * 86_400L
            hist.add(SleepStageTotals.HistoryBlock(onset, onset + 7 * 3600, "day-$d"))
        }
        assertNull("antipodal learned timing → null (cold-start fallback), not a meaningless anchor",
            SleepStageTotals.habitualMidsleepSec(hist, 0L))
    }

    // ── #547 wire-through: effective (edited) onset crosses the boundary (audit finding C / #8) ────

    /** Finding C: the seam must score on the EFFECTIVE (edited) onset, not the immutable detected key, so
     *  the seam and the Sleep tab pick the SAME block. The main block (300 asleep) is detected at 09:30
     *  (daytime → 0 bonus) but EDITED to 22:30 (overnight → ~75 bonus → ~375); a longer 340-asleep nap
     *  with no bonus loses to the effective-onset main (375>340) but BEATS the detected-onset main
     *  (340>300). The chosen block flips with the onset used — proving the fix. Mirrors Swift. */
    @Test
    fun editedOnsetCrossingBoundaryIsScoredOnTheEffectiveOnset() {
        val detectedStart = atMin(9, 30)            // detected daytime onset (bonus 0)
        val effectiveStart = atMin(22, 30) - 86_400L // user moved bedtime to the prior evening (bonus ~75)
        val napStart = atHour(15)                    // far from the band center (bonus 0)
        val mainStages = """{"awake":0,"light":150,"deep":80,"rem":70}"""   // 300 asleep
        val napStages = """{"awake":0,"light":170,"deep":90,"rem":80}"""    // 340 asleep (longer)
        val blocksByStages = listOf(detectedStart to mainStages, napStart to napStages)
        val onEffective = mapOf(detectedStart to effectiveStart, napStart to napStart)
        assertEquals(
            "effective overnight onset earns the bonus → the main block wins", 0,
            SleepStageTotals.mainNightIndexByStages(blocksByStages, onEffective, 0L),
        )
        val onDetected = mapOf(detectedStart to detectedStart, napStart to napStart)
        assertEquals(
            "detected onset misses the bonus → the longer nap mis-wins (the finding-C bug)", 1,
            SleepStageTotals.mainNightIndexByStages(blocksByStages, onDetected, 0L),
        )
        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(detectedStart to mainStages, napStart to napStages),
            edited = mapOf(detectedStart to mainStages),
            onsetByStart = onEffective, offsetSec = 0L,
        )
        assertNotNull(r)
        assertTrue(r!!.editApplied)
        assertEquals(
            "seam scores on the EFFECTIVE onset → the corrected overnight block is the day total",
            300.0, r.sleep.totalSleepMin, 1e-6,
        )
    }

    /** The habitual midsleep threads through the seam: an afternoon habitual makes a longer afternoon
     *  block the headline total over a shorter overnight one, exactly as the bare selector does. */
    @Test
    fun honoringEditsHonorsHabitualMidsleep() {
        val habitual = sod(14, 0)
        val nightStart = atHour(23) - 86_400L  // 4h overnight, mid 01:00
        val dayStart = atHour(11)              // 6h afternoon, mid 14:00 (on the habitual)
        val nightStages = """{"awake":0,"light":120,"deep":60,"rem":60}"""  // 240 asleep
        val dayStages = """{"awake":0,"light":200,"deep":80,"rem":80}"""    // 360 asleep
        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(nightStart to nightStages, dayStart to dayStages),
            edited = mapOf(dayStart to dayStages),
            onsetByStart = mapOf(nightStart to nightStart, dayStart to dayStart),
            offsetSec = 0L,
            habitualMidsleepSec = habitual,
        )
        assertNotNull(r)
        assertEquals(
            "afternoon habitual → the on-timing afternoon block is the headline total",
            360.0, r!!.sleep.totalSleepMin, 1e-6,
        )
    }

    // ── selection REASON (explainability — one test per branch) ──────────────────────────────────
    // mainNightSelection mirrors mainNightIndex (same score, same tie-break, same null-on-empty) and adds
    // the MainNightReason + the chosen block's asleep duration so the UI can explain the pick. Each branch
    // is pinned with the SAME fixtures the score uses, so a reason can never disagree with the chosen block.
    // Mirrors the Swift mainNightSelection reason tests.

    /** Empty → null, exactly like [SleepStageTotals.mainNightIndex]. */
    @Test
    fun selectionNullOnEmpty() {
        assertNull(SleepStageTotals.mainNightSelection(emptyList(), 0L))
    }

    /** REASON onlyBlock: a single block → nothing to choose between; carries that block's asleep span. */
    @Test
    fun reasonOnlyBlock() {
        val night = atHour(23) - 86_400L
        val sel = SleepStageTotals.mainNightSelection(
            listOf(SleepStageTotals.NightBlock(night, night + 7 * 3600 + 12 * 60)), 0L)
        assertNotNull(sel)
        assertEquals(0, sel!!.index)
        assertEquals(SleepStageTotals.MainNightReason.onlyBlock, sel.reason)
        assertEquals("asleep span carried for the copy (7h 12m)", 7 * 3600L + 12 * 60L, sel.asleepSec)
        assertEquals(432L, sel.asleepMin)  // 7h12m = 432 min
    }

    /** REASON longest (cold-start): no learned habitual → the longest block wins on duration; the reason is
     *  [SleepStageTotals.MainNightReason.longest] even though this chosen block ALSO earns a cold-start band
     *  bonus (a null habitual short-circuits to longest, never longestNearUsual). Same fixture as
     *  [mainNightLongestAmongOvernightBlocks] so the reason can't disagree with the pick. */
    @Test
    fun reasonLongestColdStart() {
        val a = atHour(22) - 86_400L
        val b = atHour(23) - 86_400L + 1_800L   // 23:30 onset, 6h → mid 02:30 (earns a cold-start bonus)
        val blocks = listOf(
            SleepStageTotals.NightBlock(a, a + 3 * 3600),  // 3h
            SleepStageTotals.NightBlock(b, b + 6 * 3600),  // 6h longest
        )
        // selector still picks index 1 (parity with mainNightIndex), and explains it cold-start.
        assertEquals(1, SleepStageTotals.mainNightIndex(blocks, 0L))
        val sel = SleepStageTotals.mainNightSelection(blocks, 0L)   // null habitual = cold-start
        assertNotNull(sel)
        assertEquals(1, sel!!.index)
        assertEquals("cold-start (null habitual) → longest, never longestNearUsual",
            SleepStageTotals.MainNightReason.longest, sel.reason)
        assertEquals(6 * 3600L, sel.asleepSec)
    }

    /** REASON longestNearUsual: a LEARNED habitual is present, and the chosen block is BOTH the longest by
     *  duration AND earns a non-zero alignment bonus (its midpoint sits within the bonus window of the
     *  habitual). Habitual 03:00; night onset 23:00 6h (mid 02:00 → bonus > 0) beats a shorter 1h nap on
     *  duration anyway, so the bonus did NOT flip the pick — it's "longest, near usual". */
    @Test
    fun reasonLongestNearUsual() {
        val habitual = sod(3, 0)
        val night = atHour(23) - 86_400L  // 6h, mid 02:00 — longest AND ~1h from the 03:00 habitual
        val nap = atHour(15)              // 1h afternoon, far from the habitual
        val blocks = listOf(
            SleepStageTotals.NightBlock(nap, nap + 1 * 3600),
            SleepStageTotals.NightBlock(night, night + 6 * 3600),
        )
        // duration-only winner == score winner == the night (index 1): the bonus did NOT flip it.
        assertEquals(1, SleepStageTotals.mainNightIndex(blocks, 0L, habitual))
        val sel = SleepStageTotals.mainNightSelection(blocks, 0L, habitual)
        assertNotNull(sel)
        assertEquals(1, sel!!.index)
        assertEquals("learned habitual + longest is also bonus-aligned → longestNearUsual",
            SleepStageTotals.MainNightReason.longestNearUsual, sel.reason)
        assertEquals(6 * 3600L, sel.asleepSec)
    }

    /** REASON alignedToUsual: the alignment bonus (NOT raw duration) flipped the pick. Same fixture as
     *  [habitualAlignedShorterNightBeatsLongerAfternoon]: habitual 03:00, a 5h afternoon (mid 15:30, bonus
     *  0 → score 300) is LONGER, but a 4h habitual-aligned night (mid 03:00, bonus 90 → score 330) wins on
     *  timing. Duration-only winner = the afternoon; score winner = the night → timing decided it. */
    @Test
    fun reasonAlignedToUsual() {
        val habitual = sod(3, 0)
        val afternoon = atHour(13)  // 5h = 300, mid 15:30, bonus 0  (the duration-only winner)
        val night = atHour(1)       // 4h = 240, mid 03:00, bonus 90 → 330 (the score winner)
        val blocks = listOf(
            SleepStageTotals.NightBlock(afternoon, afternoon + 5 * 3600),
            SleepStageTotals.NightBlock(night, night + 4 * 3600),
        )
        // the score winner (night, index 1) differs from the duration-only winner (afternoon, index 0).
        assertEquals(1, SleepStageTotals.mainNightIndex(blocks, 0L, habitual))
        val sel = SleepStageTotals.mainNightSelection(blocks, 0L, habitual)
        assertNotNull(sel)
        assertEquals(1, sel!!.index)
        assertEquals("a shorter well-timed block out-scored the longest → alignedToUsual (timing flipped it)",
            SleepStageTotals.MainNightReason.alignedToUsual, sel.reason)
        assertEquals("carries the CHOSEN (4h night) block's asleep span, not the longer afternoon's",
            4 * 3600L, sel.asleepSec)
    }

    /** The selection's index and the chosen block always agree with the bare [SleepStageTotals.mainNightIndex]
     *  selector across the cold-start AND learned paths — the explainer can never point at a different block
     *  than the one the score actually chose. */
    @Test
    fun selectionIndexAlwaysMatchesMainNightIndex() {
        val habitual = sod(3, 0)
        val a = atHour(23) - 86_400L
        val b = atHour(13)
        val blocks = listOf(
            SleepStageTotals.NightBlock(b, b + 5 * 3600),
            SleepStageTotals.NightBlock(a, a + 4 * 3600),
        )
        for (h in listOf(null, habitual)) {
            assertEquals(
                SleepStageTotals.mainNightIndex(blocks, 0L, h),
                SleepStageTotals.mainNightSelection(blocks, 0L, h)?.index,
            )
        }
    }

    // ── #561 biphasic gap-bridge (mainNightGroupIndices) ─────────────────────────────────────────

    /** Two overnight fragments split by a < 60-min wake gap → one group of BOTH. Mirrors Swift. */
    @Test
    fun groupIndicesBridgesTwoAdjacentFragments() {
        val a = atHour(23) - 86_400L
        val aEnd = a + 3 * 3600           // 23:00 → 02:00
        val b = aEnd + 30 * 60            // 02:30 (30-min gap < 60-min bridge)
        val blocks = listOf(
            SleepStageTotals.NightBlock(a, aEnd),
            SleepStageTotals.NightBlock(b, b + 3 * 3600),
        )
        assertEquals(listOf(0, 1), SleepStageTotals.mainNightGroupIndices(blocks, 0L))
    }

    /** A long wake gap is NOT bridged — only the winning main block is the group. */
    @Test
    fun groupIndicesDoesNotBridgeLongGap() {
        val a = atHour(23) - 86_400L
        val aEnd = a + 5 * 3600           // 5h overnight (the main night)
        val b = aEnd + 5 * 3600           // 5h gap >> bridge
        val blocks = listOf(
            SleepStageTotals.NightBlock(a, aEnd),
            SleepStageTotals.NightBlock(b, b + 2 * 3600),
        )
        assertEquals(listOf(0), SleepStageTotals.mainNightGroupIndices(blocks, 0L))
    }

    /** No gap → the group is exactly the single block mainNightIndex would pick (no regression). */
    @Test
    fun groupIndicesSingleBlockMatchesBareSelector() {
        val s = atHour(0)
        val blocks = listOf(SleepStageTotals.NightBlock(s, s + 7 * 3600))
        assertEquals(listOf(0), SleepStageTotals.mainNightGroupIndices(blocks, 0L))
        assertNull(SleepStageTotals.mainNightGroupIndices(emptyList(), 0L))
    }

    /** A bridged biphasic night (2h + gap + 2h) out-scores a lone 3h nap, returning BOTH its fragments. */
    @Test
    fun groupIndicesBridgedNightOutscoresLoneNap() {
        val f1 = atHour(23) - 86_400L
        val f1End = f1 + 2 * 3600
        val f2 = f1End + 20 * 60
        val f2End = f2 + 2 * 3600
        val nap = atHour(13)
        val blocks = listOf(
            SleepStageTotals.NightBlock(f1, f1End),
            SleepStageTotals.NightBlock(nap, nap + 3 * 3600),
            SleepStageTotals.NightBlock(f2, f2End),
        )
        assertEquals(listOf(0, 2), SleepStageTotals.mainNightGroupIndices(blocks, 0L))
    }

    // ── #861 a real overnight night split by a 60–90 min wake is ONE sleep, not nap + sleep ──────────

    /** The reported pattern (#861): one overnight sleep the detector left split into two fragments by a real
     *  ~70-min mid-night wake, longer than the old 60-min bridge, so the later fragment lost the main-night
     *  pick and was LABELLED A NAP. The wider overnight night-tail bridge (≤ NIGHT_TAIL_BRIDGE_MAX_MIN, onset
     *  still in the overnight band) now folds both fragments into ONE main-night group, so neither is a nap.
     *  Honest-data invariant: no stage is invented; the gap is folded into AWAKE by the aggregate. Mirrors
     *  Swift `testOvernightNightSplitBySeventyMinuteWakeMergesIntoOneSleepNotNap`. */
    @Test
    fun overnightNightSplitBySeventyMinuteWakeMergesIntoOneSleepNotNap() {
        val a = atMin(23, 30) - 86_400L              // overnight onset
        val aEnd = a + 3 * 3600                       // 23:30 → 02:30
        val b = aEnd + 70 * 60                        // 03:40 onset (70-min gap; 60 ≤ gap < 90)
        val bEnd = b + 4 * 3600                       // 03:40 → 07:40 (the longer tail)
        val blocks = listOf(
            SleepStageTotals.NightBlock(a, aEnd),
            SleepStageTotals.NightBlock(b, bEnd),
        )
        assertEquals(listOf(0, 1), SleepStageTotals.mainNightGroupIndices(blocks, 0L))
        // The wider bridge lives only in mainNightGroupIndices; bridgeAdjacent's <60-min contract is unchanged.
        assertEquals(2, SleepStageTotals.bridgeAdjacent(blocks).size)
    }

    /** The daytime guard the widening must NOT breach: a genuine afternoon nap (daytime onset) stays its OWN
     *  block, because the wider bridge requires an overnight-band onset. Mirrors Swift
     *  `testDaytimeNapWithSeventyMinuteGapStillStaysItsOwnBlock`. */
    @Test
    fun daytimeNapStillStaysItsOwnBlockUnderWiderBridge() {
        val night = atHour(0)                         // 00:00 → 06:00 overnight
        val nightEnd = night + 6 * 3600
        val nap = atHour(13)                          // 13:00 daytime onset → never a night-tail
        val blocks = listOf(
            SleepStageTotals.NightBlock(night, nightEnd),
            SleepStageTotals.NightBlock(nap, nap + 90 * 60),
        )
        assertEquals(listOf(0), SleepStageTotals.mainNightGroupIndices(blocks, 0L))
    }

    /** The upper guard: a wake gap at/over NIGHT_TAIL_BRIDGE_MAX_MIN (90 min) is NOT a mid-night wake, so the
     *  blocks stay separate even for an overnight-band onset. Mirrors Swift
     *  `testOvernightGapAtOrAboveNinetyMinutesDoesNotBridge`. */
    @Test
    fun overnightGapAtOrAboveNinetyMinutesDoesNotBridge() {
        val a = atHour(23) - 86_400L
        val aEnd = a + 3 * 3600                        // 23:00 → 02:00
        val b = aEnd + 95 * 60                         // 03:35 onset (95-min gap ≥ 90)
        val blocks = listOf(
            SleepStageTotals.NightBlock(a, aEnd),
            SleepStageTotals.NightBlock(b, b + 4 * 3600),
        )
        assertEquals(listOf(1), SleepStageTotals.mainNightGroupIndices(blocks, 0L))
    }

    /**
     * IRON-RULE REGRESSION GUARD (#547 / #407 lanes): the 6.1.1 bridged main-night SELECTION must NOT move
     * when the upstream ingest gate (#547) or the downstream motion trace (#407) change. Pins
     * `mainNightGroupIndices` for a biphasic main night to a BYTE-IDENTICAL frozen golden so any edit that
     * perturbs the bridge/selection is caught. Kotlin twin of the Swift
     * `testMainNightGroupIndicesByteIdenticalForBiphasicNight`.
     */
    @Test
    fun mainNightGroupIndicesByteIdenticalForBiphasicNight() {
        // Two night fragments split by a 35-min wake gap (bridges) + a far afternoon nap (does NOT bridge).
        val a = atMin(23, 10) - 86_400L            // 23:10 → 01:30 (140 min)
        val aEnd = a + 140 * 60
        val b = aEnd + 35 * 60                       // 02:05, 35-min gap → bridges
        val bEnd = b + 275 * 60                      // → 06:40
        val nap = atHour(15)                         // 15:00 → 16:20 (far → no bridge)
        val blocks = listOf(
            SleepStageTotals.NightBlock(a, aEnd),    // idx 0
            SleepStageTotals.NightBlock(b, bEnd),    // idx 1
            SleepStageTotals.NightBlock(nap, nap + 80 * 60), // idx 2
        )
        // FROZEN GOLDEN: the two bridged night fragments are the group; the nap is excluded. A change here
        // means the 6.1.1 main-night selection moved — STOP and investigate (the iron rule).
        assertEquals(listOf(0, 1), SleepStageTotals.mainNightGroupIndices(blocks, 0L))
        // Cold-start and learned-habitual both land identically (duration dominates), proving neither path
        // perturbs the bridge.
        val habitualMid = ((a + 70 * 60) % 86_400L)
        assertEquals(listOf(0, 1), SleepStageTotals.mainNightGroupIndices(blocks, 0L, habitualMid))
        assertTrue(SleepStageTotals.mainNightIndex(blocks, 0L) in listOf(0, 1))
    }

    /** The stages-path seam SUMS the bridged biphasic group (analyzeDay parity), not the longest fragment. */
    @Test
    fun honoringEditsSumsBiphasicGroup() {
        val a = atHour(23) - 86_400L
        val aStages = """{"awake":8,"light":24,"deep":82,"rem":96}"""   // 202 asleep + 8 wake = 210 in-bed
        val aInBedSec = 210 * 60
        val b = a + aInBedSec + 20 * 60                                  // 20-min wake gap < 60-min bridge
        val bStages = """{"awake":10,"light":20,"deep":90,"rem":70}"""   // 180 asleep
        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(a to aStages, b to bStages),
            edited = emptyMap(),
            onsetByStart = mapOf(a to a, b to b),
            offsetSec = 0L,
        )
        assertNotNull(r)
        assertEquals("the seam SUMS the bridged biphasic group", 382.0, r!!.sleep.totalSleepMin, 1e-6)
        assertEquals(172.0, r.sleep.deepMin, 1e-6)   // 82 + 90
    }
}
