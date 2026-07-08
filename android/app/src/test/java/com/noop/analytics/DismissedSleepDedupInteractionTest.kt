package com.noop.analytics

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #65 x #899 x #940 interaction (Kotlin twin of the Swift DismissedSleepDedupInteractionTests).
 *
 * A dismissed (deleted) sleep window must stay dismissed across a dedup/heal + rescore: the engine's
 * re-detection guard ([DismissedSleepGuard.keeping]) filters a re-detected overlapping session BEFORE it
 * is ever banked, so the #899 [SleepSessionDedup] heal (which only ever operates on rows that DID get
 * banked) can never resurrect a suppressed night. This models the exact engine sequence: filter the
 * re-detected sessions against the tombstones, upsert the survivors, then run the overlap-dedup heal over
 * the stored set, and asserts the suppressed window is gone at every step.
 */
class DismissedSleepDedupInteractionTest {

    private fun session(start: Long, end: Long, edited: Boolean = false) =
        SleepSession(deviceId = "my-whoop-noop", startTs = start, endTs = end, userEdited = edited)

    @Test fun dismissedWindowIsDroppedBeforeBankingAndStaysDroppedAfterDedup() {
        // Night A (kept), Night B (DELETED). A re-detects clean; B re-detects with a drifted onset,
        // still overlapping the tombstone (written under the imported "my-whoop" id, #65 3A).
        val nightA = session(100_000, 128_000)
        val nightBReDetected = session(200_500, 228_000) // drifted 500s from the deleted onset
        val tombstones = listOf(200_000L to 228_000L)

        // STEP 1 (engine guard): B is suppressed, A survives.
        val survivors = DismissedSleepGuard.keeping(listOf(nightA, nightBReDetected), tombstones) { it.startTs to it.endTs }
        assertEquals(
            "the re-detected deleted night is filtered before it is ever banked",
            listOf(nightA.startTs), survivors.map { it.startTs },
        )

        // STEP 2 (the #899 heal) runs over the BANKED set (only the survivors were upserted). A stale,
        // timebase-shifted duplicate of night A got banked on an earlier pass; the heal collapses it.
        val staleADuplicate = session(100_500, 128_500) // overlaps A -> same night, drop it
        val banked = survivors + staleADuplicate
        val result = SleepSessionDedup.dedupe(banked, freshStarts = setOf(nightA.startTs))
        assertEquals(listOf(nightA.startTs), result.kept.map { it.startTs })

        // STEP 3 (invariant): the dedup heal NEVER re-introduces the suppressed window.
        assertFalse(
            "no kept row overlaps the dismissed window after a dedup+rescore",
            result.kept.any { DismissedSleepGuard.isSuppressed(it.startTs, it.endTs, tombstones) },
        )
    }

    @Test fun removingTheTombstoneReAdmitsTheNightOnTheNextPass() {
        val nightBReDetected = session(200_500, 228_000)
        val tombstoned = listOf(200_000L to 228_000L)
        // While tombstoned: suppressed.
        assertTrue(
            DismissedSleepGuard.keeping(listOf(nightBReDetected), tombstoned) { it.startTs to it.endTs }.isEmpty(),
        )
        // Remove the tombstone (undo / allow re-detection) -> re-admitted.
        val lifted = emptyList<Pair<Long, Long>>()
        assertEquals(
            listOf(nightBReDetected.startTs),
            DismissedSleepGuard.keeping(listOf(nightBReDetected), lifted) { it.startTs to it.endTs }.map { it.startTs },
        )
    }

    @Test fun editedNightIsNeverDroppedByTheDedupHeal() {
        // A userEdited night is exempt from dedup drops (SleepSessionDedup keeps edited rows), and the
        // delete path writes NO tombstone for it, so a userEdited night is never suppressed here.
        val edited = session(300_000, 328_000, edited = true)
        val overlappingDetected = session(300_200, 328_000)
        val result = SleepSessionDedup.dedupe(listOf(edited, overlappingDetected), freshStarts = setOf(overlappingDetected.startTs))
        assertTrue("the edited night is never dropped by the heal", result.kept.any { it.userEdited })
    }
}
