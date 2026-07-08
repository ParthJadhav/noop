package com.noop.analytics

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #65: the tombstone-WRITE policy on delete (pure), paired with the #899 heal invariant.
 *
 * A DETECTED night's delete writes a suppression tombstone so the recompute does not silently regenerate
 * it. A user-created/edited night (`userEdited`) is deleted WITHOUT one: it is never re-detected, so
 * suppressing its window would wrongly block a real future night. The #899 dedup heal deletes stale
 * timebase-shifted duplicates via a SEPARATE tombstone-free path ([WhoopRepository.deleteSleepSessionRowOnly]),
 * so a heal can never permanently suppress the surviving night. These pin the decision the repository makes.
 */
class SleepDeleteTombstonePolicyTest {

    @Test fun detectedNightDeleteWritesATombstone() {
        assertTrue(
            "a detected night must be tombstoned so the recompute doesn't regenerate it",
            DismissedSleepGuard.writesTombstoneOnDelete(userEdited = false),
        )
    }

    @Test fun userEditedNightDeleteWritesNoTombstone() {
        assertFalse(
            "a hand-corrected night / manual nap is never re-detected, so it needs no tombstone",
            DismissedSleepGuard.writesTombstoneOnDelete(userEdited = true),
        )
    }
}
