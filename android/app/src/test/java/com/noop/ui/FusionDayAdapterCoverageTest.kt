package com.noop.ui

import com.noop.analytics.FusionSource
import com.noop.data.DailyMetric
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * #799 / SPINE regression: the fused record only lets a source win the day it ACTUALLY covers, and the
 * strap reads follow the registry's ACTIVE strap id (not a hardcoded "my-whoop"). The reported symptom was
 * "fused 8h57m every day": one imported sleep row appeared to win every day. [FusionDayAdapter.buildFor]
 * must read each source's OWN row keyed to the exact requested day, so an import for day A never supplies a
 * value for day B; and an active band stored under its own id must fuse ITS data, not the WHOOP id's.
 *
 * Mirrors the iOS regression test logic. Driven through a Proxy-stub [WhoopDao] (no Room): the only DAO
 * method [FusionDayAdapter] touches is `days(deviceId)`, which we answer per device id from a fixture map.
 */
class FusionDayAdapterCoverageTest {

    /** Build a repository whose `days(deviceId)` returns the fixture rows for that id (else empty), and
     *  whose every OTHER dao call throws (proof the adapter touches nothing else). */
    private fun repo(rowsByDevice: Map<String, List<DailyMetric>>): WhoopRepository {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                // The ONLY DAO method FusionDayAdapter touches (via repo.days). args[0] is the deviceId;
                // a trailing Continuation (suspend ABI) is ignored. Returning the list synchronously is the
                // supported way to stub a suspend fun through a Java Proxy.
                "days" -> rowsByDevice[args?.get(0) as String].orEmpty()
                // Anything else proves the adapter reached past its contract.
                else -> throw UnsupportedOperationException("FusionDayAdapter must not call ${method.name}")
            }
        } as WhoopDao
        return WhoopRepository(dao)
    }

    private fun sleepRow(deviceId: String, day: String, asleepMin: Double) =
        DailyMetric(deviceId = deviceId, day = day, totalSleepMin = asleepMin)

    private val dayA = "2026-06-10"
    private val dayB = "2026-06-11"

    @Test
    fun importedSleepRowDoesNotWinADayItDoesNotCover() = runBlocking {
        // The import covers ONLY dayA with 8h57m (537 min). Building the record for dayB must NOT carry
        // that value forward (the "fused 8h57m every day" bug).
        val repo = repo(
            mapOf("my-whoop" to listOf(sleepRow("my-whoop", dayA, 537.0))),
        )

        val recA = FusionDayAdapter.buildFor(repo, dayA)
        val recB = FusionDayAdapter.buildFor(repo, dayB)

        // dayA has the imported asleep value; dayB has NO source for it.
        val sleepA = recA.rows.firstOrNull { it.point.metric == "sleep_total_min" }
        assertEquals(537.0, sleepA?.point?.value)
        val sleepB = recB.rows.firstOrNull { it.point.metric == "sleep_total_min" }
        assertNull("an import for dayA must not supply sleep for dayB", sleepB)
        // dayB has no contributing source at all -> empty record, never a carried-forward number.
        assertEquals(0, recB.contributingSourceCount)
        assertTrue(recB.rows.isEmpty())
    }

    @Test
    fun strapReadsFollowTheActiveStrapIdNotHardcodedMyWhoop() = runBlocking {
        // The active band stores its day under its OWN id. A hardcoded "my-whoop" read would miss it; the
        // active-id read fuses it. (SPINE / #814.)
        val activeId = "polar-h10"
        val repo = repo(
            mapOf(activeId to listOf(sleepRow(activeId, dayA, 480.0))),
        )

        // Default (hardcoded my-whoop) sees nothing for this band.
        val hardcoded = FusionDayAdapter.buildFor(repo, dayA)
        assertEquals(0, hardcoded.contributingSourceCount)

        // Active-id read fuses the band's own row, and attributes it to the WHOOP_IMPORT strap slot.
        val active = FusionDayAdapter.buildFor(repo, dayA, activeStrapId = activeId)
        val sleep = active.rows.firstOrNull { it.point.metric == "sleep_total_min" }
        assertEquals(480.0, sleep?.point?.value)
        assertEquals(FusionSource.WHOOP_IMPORT, sleep?.point?.winningSource)
    }

    @Test
    fun computedSiblingAlsoFollowsTheActiveStrapId() = runBlocking {
        // The on-device computed sibling is "<activeStrapId>-noop", not "my-whoop-noop".
        val activeId = "garmin-hrm"
        val repo = repo(
            mapOf("$activeId-noop" to listOf(sleepRow("$activeId-noop", dayA, 421.0))),
        )
        val rec = FusionDayAdapter.buildFor(repo, dayA, activeStrapId = activeId)
        val sleep = rec.rows.firstOrNull { it.point.metric == "sleep_total_min" }
        assertEquals(421.0, sleep?.point?.value)
        assertEquals(FusionSource.NOOP_COMPUTED, sleep?.point?.winningSource)
    }
}
