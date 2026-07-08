package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Regression pin for #993: dailyMetric.totalSleepMin read 450 min (7h30) on nights whose session rows
 * were correct, so sleep debt showed 0 and hours-vs-need 100 on every surface except the Sleep screen.
 *
 * Mechanism: the Health Connect importer backfills a "my-whoop" daily row carrying ONLY totalSleepMin
 * (efficiency / deep / rem / light all null). On the reporter's Pixel the OS banked a stage-less
 * bedtime-SCHEDULE SleepSessionRecord, so the importer's span fallback wrote the SCHEDULE length , a
 * constant 450 = the 23:00-06:30 default, a target, never measured sleep. The on-open HC auto-sync
 * races the analyze pass (the fresh day has no computed row yet, so the importer's coveredDays guard
 * misses it), and the imports-win coalesce in [WhoopRepository.mergeDaily] then kept the 450 forever.
 *
 * The fix (in mergeDaily, the read-side daily rollup, so already-shadowed days HEAL): a bare imported
 * sleep total loses the WHOLE sleep block to a computed row that scored a real night; session-grade
 * imports (efficiency/stages beside the total) and HC-only users (no computed night) are unchanged.
 * All pure (no Room) , exercises the companion [WhoopRepository.mergeDaily] directly, in the style of
 * [EditMergePrecedenceTest].
 */
class Issue993BareSleepTotalMergeTest {

    /** The #993 shape: the HC backfill row , a bare sleep total (the 450-min schedule span) plus the
     *  daily aggregates HC genuinely measures (resting HR / HRV), everything sleep-detail null. */
    private fun hcBackfillRow(day: String, totalSleepMin: Double = 450.0) = DailyMetric(
        deviceId = "my-whoop",
        day = day,
        totalSleepMin = totalSleepMin,
        restingHr = 55,
        avgHrv = 62.0,
    )

    /** A strap-scored computed night (the real sleep the reporter's export showed under sleepSession). */
    private fun scoredNight(day: String) = DailyMetric(
        deviceId = "my-whoop-noop",
        day = day,
        totalSleepMin = 341.0,
        efficiency = 0.94,
        deepMin = 62.0,
        remMin = 78.0,
        lightMin = 201.0,
        disturbances = 3,
        restingHr = 52,
        avgHrv = 71.0,
        recovery = 74.0,
        strain = 41.0,
    )

    @Test
    fun bareImportedTotal_neverOverridesScoredNight() {
        val merged = WhoopRepository.mergeDaily(
            imported = listOf(hcBackfillRow("2026-06-28")),
            computed = listOf(scoredNight("2026-06-28")),
        )

        assertEquals(1, merged.size)
        // The WHOLE sleep block comes from the scored night , the reporter's actual minutes, never the
        // 450-min schedule target, and never a mixed row (450 total beside computed stage minutes).
        assertEquals(341.0, merged[0].totalSleepMin!!, 0.0)
        assertEquals(0.94, merged[0].efficiency!!, 0.0)
        assertEquals(62.0, merged[0].deepMin!!, 0.0)
        assertEquals(78.0, merged[0].remMin!!, 0.0)
        assertEquals(201.0, merged[0].lightMin!!, 0.0)
        assertEquals(3, merged[0].disturbances)
        // Non-sleep fields keep the imports-win merge: HC's measured daily aggregates still win.
        assertEquals(55, merged[0].restingHr)
        assertEquals(62.0, merged[0].avgHrv!!, 0.0)
        // Fields the import left null are still gap-filled from the computed row (#112 unchanged).
        assertEquals(74.0, merged[0].recovery!!, 0.0)
        assertEquals(41.0, merged[0].strain!!, 0.0)
    }

    @Test
    fun bareImportedTotal_fillsWhenNoScoredNight() {
        // HC-only population (#983): the computed row has no scored night, so the bare total is the
        // only sleep there is and MUST survive , the guard may not blank a genuine HC-only user.
        val computedNoSleep = DailyMetric(
            deviceId = "my-whoop-noop", day = "2026-06-28", strain = 38.0, steps = 8200,
        )
        val merged = WhoopRepository.mergeDaily(
            imported = listOf(hcBackfillRow("2026-06-28")),
            computed = listOf(computedNoSleep),
        )
        assertEquals(450.0, merged[0].totalSleepMin!!, 0.0)
        assertEquals(8200, merged[0].steps)
    }

    @Test
    fun bareImportedTotal_passesThroughWithNoComputedRow() {
        // No computed row at all (pure import day): unchanged pass-through.
        val merged = WhoopRepository.mergeDaily(
            imported = listOf(hcBackfillRow("2026-06-28")),
            computed = emptyList(),
        )
        assertEquals(450.0, merged[0].totalSleepMin!!, 0.0)
        assertNull(merged[0].efficiency)
    }

    @Test
    fun sessionGradeImport_stillWinsOverComputed() {
        // A real WHOOP CSV row always carries efficiency + stage minutes beside the total ,
        // session-grade, so the existing imports-win precedence is byte-identical.
        val whoopCsvRow = DailyMetric(
            deviceId = "my-whoop", day = "2026-06-28",
            totalSleepMin = 480.0, efficiency = 0.92,
            deepMin = 90.0, remMin = 110.0, lightMin = 280.0,
        )
        val merged = WhoopRepository.mergeDaily(
            imported = listOf(whoopCsvRow),
            computed = listOf(scoredNight("2026-06-28")),
        )
        assertEquals(480.0, merged[0].totalSleepMin!!, 0.0)
        assertEquals(90.0, merged[0].deepMin!!, 0.0)
        assertEquals(0.92, merged[0].efficiency!!, 0.0)
    }

    @Test
    fun importWithEfficiencyOnly_isSessionGrade() {
        // Some exports carry a total + efficiency but no stage split (e.g. a stage-less tracker's
        // genuine measurement). Efficiency is session evidence , the import keeps winning.
        val effOnly = DailyMetric(
            deviceId = "my-whoop", day = "2026-06-28",
            totalSleepMin = 402.0, efficiency = 0.88,
        )
        val merged = WhoopRepository.mergeDaily(
            imported = listOf(effOnly),
            computed = listOf(scoredNight("2026-06-28")),
        )
        assertEquals(402.0, merged[0].totalSleepMin!!, 0.0)
        assertEquals(0.88, merged[0].efficiency!!, 0.0)
        // Stage minutes the import lacks still gap-fill from the computed row (#112 coalesce).
        assertEquals(62.0, merged[0].deepMin!!, 0.0)
    }

    // MARK: - bareSleepAggregate predicate (the one shared definition)

    @Test
    fun bareSleepAggregate_matchesHcBackfillShapeOnly() {
        // The HC backfill shape (total only) is bare; anything with efficiency or a stage minute
        // beside the total is session-grade; no total at all is not a sleep block to judge.
        org.junit.Assert.assertTrue(WhoopRepository.bareSleepAggregate(hcBackfillRow("2026-06-28")))
        org.junit.Assert.assertFalse(WhoopRepository.bareSleepAggregate(scoredNight("2026-06-28")))
        org.junit.Assert.assertFalse(
            WhoopRepository.bareSleepAggregate(
                DailyMetric(deviceId = "my-whoop", day = "2026-06-28", totalSleepMin = 402.0, efficiency = 0.88),
            ),
        )
        org.junit.Assert.assertFalse(
            WhoopRepository.bareSleepAggregate(
                DailyMetric(deviceId = "my-whoop", day = "2026-06-28", restingHr = 55),
            ),
        )
    }

    // MARK: - Cross-source resolver seam (#993 second read path)
    //
    // Compare / Lab Book resolve "sleep_total_min" through resolvedSeries, which reads RAW per-source
    // rows and never passes mergeDaily , so the bare 450 under "my-whoop" (candidate 0) would have kept
    // winning there even after the merge fix. resolveFirstWins is the resolver's pure per-day merge:
    // pin that a WEAK sleep-total yields to a later candidate's scored value and nothing else moves.

    private fun candidate(source: String) = WhoopRepository.MetricSourceCandidate(source, "sleep_total_min")

    @Test
    fun resolver_weakSleepTotal_supersededByScoredNight() {
        val points = WhoopRepository.resolveFirstWins(
            listOf(
                candidate("my-whoop") to listOf(
                    WhoopRepository.CandidateRow("2026-06-28", 450.0, weakSleepTotal = true),
                ),
                candidate("my-whoop-noop") to listOf(
                    WhoopRepository.CandidateRow("2026-06-28", 341.0),
                ),
            ),
        )
        assertEquals(1, points.size)
        assertEquals(341.0, points[0].value, 0.0)
        assertEquals("my-whoop-noop", points[0].source)
    }

    @Test
    fun resolver_weakSleepTotal_keptWhenNoStrongerSibling() {
        // HC-only user: the weak total is the only sleep there is , it must survive, never blank.
        val points = WhoopRepository.resolveFirstWins(
            listOf(
                candidate("my-whoop") to listOf(
                    WhoopRepository.CandidateRow("2026-06-28", 450.0, weakSleepTotal = true),
                ),
                candidate("my-whoop-noop") to emptyList(),
            ),
        )
        assertEquals(450.0, points[0].value, 0.0)
        assertEquals("my-whoop", points[0].source)
    }

    @Test
    fun resolver_strongFirstCandidate_precedenceByteIdentical() {
        // A session-grade import (never flagged weak) keeps winning over the computed candidate ,
        // the historical first-wins behaviour, unchanged.
        val points = WhoopRepository.resolveFirstWins(
            listOf(
                candidate("my-whoop") to listOf(WhoopRepository.CandidateRow("2026-06-28", 480.0)),
                candidate("my-whoop-noop") to listOf(WhoopRepository.CandidateRow("2026-06-28", 341.0)),
            ),
        )
        assertEquals(480.0, points[0].value, 0.0)
        assertEquals("my-whoop", points[0].source)
    }

    @Test
    fun resolver_laterWeakNeverReplacesEarlierValue() {
        // Symmetry guard: weakness only ever CONCEDES a day, it never claims one already taken.
        val points = WhoopRepository.resolveFirstWins(
            listOf(
                candidate("my-whoop") to listOf(WhoopRepository.CandidateRow("2026-06-28", 341.0)),
                candidate("my-whoop-noop") to listOf(
                    WhoopRepository.CandidateRow("2026-06-28", 450.0, weakSleepTotal = true),
                ),
            ),
        )
        assertEquals(341.0, points[0].value, 0.0)
        assertEquals("my-whoop", points[0].source)
    }

    @Test
    fun resolver_fillsAcrossDaysAndSortsAscending() {
        // Multi-day shape check: later candidates fill uncovered days; output stays day-ascending.
        val points = WhoopRepository.resolveFirstWins(
            listOf(
                candidate("my-whoop") to listOf(
                    WhoopRepository.CandidateRow("2026-06-29", 450.0, weakSleepTotal = true),
                ),
                candidate("my-whoop-noop") to listOf(
                    WhoopRepository.CandidateRow("2026-06-28", 322.0),
                    WhoopRepository.CandidateRow("2026-06-29", 355.0),
                ),
            ),
        )
        assertEquals(listOf("2026-06-28" to 322.0, "2026-06-29" to 355.0), points.map { it.day to it.value })
    }

    @Test
    fun editedDay_precedenceUnchangedByGuard() {
        // H5 (#509) still holds with the #993 guard in place: an edited day takes the computed sleep
        // block even against a session-grade import.
        val whoopCsvRow = DailyMetric(
            deviceId = "my-whoop", day = "2026-06-28",
            totalSleepMin = 480.0, efficiency = 0.92,
            deepMin = 90.0, remMin = 110.0, lightMin = 280.0,
        )
        val merged = WhoopRepository.mergeDaily(
            imported = listOf(whoopCsvRow),
            computed = listOf(scoredNight("2026-06-28")),
            userEditedDays = setOf("2026-06-28"),
        )
        assertEquals(341.0, merged[0].totalSleepMin!!, 0.0)
        assertEquals(62.0, merged[0].deepMin!!, 0.0)
    }
}
