package com.noop.analytics

/**
 * The pure logic behind a DELETED sleep night's durable tombstone (#65/#33), the Kotlin twin of Swift's
 * `DismissedSleepSpans`.
 *
 * Deleting a DETECTED sleep must suppress its re-detection so the night does not silently come back on the
 * next analyze pass, WITH an undo. Android stores the tombstones in the `dismissedSleep` Room table under
 * the deleted row's OWN `deviceId`; this object owns everything about the read/guard that has no DB I/O,
 * so it runs on the JVM with no Room and stays in lockstep with the Swift twin.
 *
 * HAZARD 1 (#65 3A): the tombstone is written under `session.deviceId` ("my-whoop" for an IMPORTED night,
 * "my-whoop-noop" for a computed one), but the engine guard used to read ONLY the computed id, so a deleted
 * IMPORTED night's tombstone was never consulted and a raw re-detection resurrected it as a computed twin.
 * The fix is the UNION read ([WhoopRepository.dismissedSleeps] reads both ids); this object's overlap test
 * then works whatever id the tombstone was written under.
 */
object DismissedSleepGuard {

    /** True when `[sessionStart, sessionEnd)` time-overlaps ANY dismissed `(start, end)` window: the
     *  engine's re-detection guard predicate. Overlap (not exact startTs) because a re-detected onset
     *  drifts as more raw data arrives. Half-open `<` test, matching the Swift twin and the engine. */
    fun isSuppressed(
        sessionStart: Long,
        sessionEnd: Long,
        dismissedWindows: List<Pair<Long, Long>>,
    ): Boolean = dismissedWindows.any { (start, end) -> sessionStart < end && start < sessionEnd }

    /** Drop every session in [sessions] that overlaps a dismissed window: the engine's `sleepKept`
     *  filter, as a pure function so a JVM test can pin it. [windowOf] projects a session to its
     *  `(start, end)` detected window. */
    fun <T> keeping(
        sessions: List<T>,
        dismissedWindows: List<Pair<Long, Long>>,
        windowOf: (T) -> Pair<Long, Long>,
    ): List<T> = sessions.filterNot {
        val (s, e) = windowOf(it)
        isSuppressed(s, e, dismissedWindows)
    }

    /** Whether deleting a night writes a suppression tombstone (#65). A DETECTED night is tombstoned so
     *  the recompute does not regenerate it. A user-created/edited (`userEdited`) night (a hand-corrected
     *  night or a manually-added nap) is deleted WITHOUT a tombstone: it is never re-detected, so
     *  suppressing its window would needlessly block a real future night overlapping it. */
    fun writesTombstoneOnDelete(userEdited: Boolean): Boolean = !userEdited
}
