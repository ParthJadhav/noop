package com.noop.analytics

import com.noop.data.DismissedSleep
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #65: deleting a DETECTED sleep writes a durable tombstone so the next analyze pass does not silently
 * re-detect + re-insert it. [DismissedSleepGuard] is the pure overlap-suppression logic behind the engine
 * guard (the JVM-testable twin of Swift `DismissedSleepSpans`), and this pins HAZARD 1: the read-side
 * UNION of the imported + computed id namespaces means a tombstone written under EITHER id suppresses a
 * re-detected night, with NO data migration.
 */
class DismissedSleepGuardTest {

    private fun window(start: Long, end: Long) = start to end

    // --- Overlap-suppression predicate ---

    @Test fun overlappingReDetectedSessionIsSuppressed() {
        val windows = listOf(window(1000, 2000))
        // A re-detected onset that drifted a little still overlaps the dismissed span.
        assertTrue(DismissedSleepGuard.isSuppressed(1100, 2100, windows))
        assertTrue(DismissedSleepGuard.isSuppressed(900, 1500, windows))
    }

    @Test fun disjointSessionIsNotSuppressed() {
        val windows = listOf(window(1000, 2000))
        // Half-open: touching at an edge does not overlap.
        assertFalse(DismissedSleepGuard.isSuppressed(2000, 3000, windows))
        assertFalse(DismissedSleepGuard.isSuppressed(0, 1000, windows))
        assertFalse(DismissedSleepGuard.isSuppressed(5000, 6000, windows))
    }

    @Test fun emptyWindowsSuppressNothing() {
        assertFalse(DismissedSleepGuard.isSuppressed(1000, 2000, emptyList()))
    }

    // --- HAZARD 1: a tombstone written under EITHER namespace suppresses a computed re-detect ---

    @Test fun tombstoneUnderImportedIdSuppressesAComputedReDetect() {
        // The exact bug: the user deleted an IMPORTED night, so the tombstone was written under
        // "my-whoop". A later strap raw re-detection banks the SAME window under the COMPUTED source.
        // The engine reads the UNION of both ids (WhoopRepository.dismissedSleeps), so this tombstone
        // is now consulted and the computed re-detect is dropped.
        val importedTombstone = DismissedSleep(deviceId = "my-whoop", startTs = 200_000, endTs = 228_000)
        val computedTombstone = DismissedSleep(deviceId = "my-whoop-noop", startTs = 100_000, endTs = 128_000)
        // The union the repository returns (dao.dismissedSleeps("my-whoop") + dao.dismissedSleeps("my-whoop-noop")).
        val union = listOf(importedTombstone, computedTombstone).map { it.startTs to it.endTs }

        // A computed re-detect over the IMPORTED tombstone's window (onset drifted 500s) is suppressed.
        assertTrue(
            "an imported night's tombstone must suppress a computed re-detect over the same window",
            DismissedSleepGuard.isSuppressed(200_500, 228_000, union),
        )
        // And a computed re-detect over the computed tombstone's window is still suppressed (unchanged).
        assertTrue(DismissedSleepGuard.isSuppressed(100_200, 128_000, union))
    }

    @Test fun readingOnlyTheComputedIdWouldMissTheImportedTombstone() {
        // Regression witness for the pre-fix behaviour: if the read consulted ONLY the computed id, an
        // imported night's tombstone would be invisible and the night would resurrect.
        val importedOnly = listOf(DismissedSleep("my-whoop", 200_000, 228_000))
        val computedIdOnlyView = importedOnly.filter { it.deviceId == "my-whoop-noop" }.map { it.startTs to it.endTs }
        assertFalse(
            "the pre-fix computed-only read never saw the imported tombstone",
            DismissedSleepGuard.isSuppressed(200_500, 228_000, computedIdOnlyView),
        )
        // The union view (the fix) DOES see it.
        val unionView = importedOnly.map { it.startTs to it.endTs }
        assertTrue(DismissedSleepGuard.isSuppressed(200_500, 228_000, unionView))
    }

    // --- The engine's sleepKept filter (pure) ---

    @Test fun keepingDropsOverlappingSessionsAndKeepsTheRest() {
        data class Night(val start: Long, val end: Long)
        val nights = listOf(Night(100_000, 128_000), Night(200_500, 228_000), Night(300_000, 328_000))
        // Dismiss the middle night's window (via an imported-id tombstone).
        val dismissed = listOf(window(200_000, 228_000))
        val kept = DismissedSleepGuard.keeping(nights, dismissed) { it.start to it.end }
        assertEquals(listOf(Night(100_000, 128_000), Night(300_000, 328_000)), kept)
    }
}
