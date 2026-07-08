package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Day-navigation contract tests (#817) - the pure offset math shared by the Today header chevrons and the
 * horizontal swipe. `selectedDayOffset` is days-back-from-today (0 = today). The rules under test:
 *  - older steps up without bound (browse arbitrarily far back),
 *  - newer steps down but is CLAMPED at 0 (a future day is never selectable),
 *  - `canGoNewer` is false only on today,
 *  - a swipe under the threshold is a no-op; over it, rightward = older, leftward = newer (clamped).
 *
 * Mirrors the iOS DayNavBar's `selectedOffset ± 1` + `canGoNewer` gate, so the two platforms navigate days
 * identically.
 */
class DayNavTest {

    // ── older / newer stepping ──────────────────────────────────────────────────

    @Test fun olderStepsBackByOne() {
        assertEquals(1, dayNavOlder(0))
        assertEquals(2, dayNavOlder(1))
        assertEquals(366, dayNavOlder(365))
    }

    @Test fun newerStepsForwardByOneButClampsAtToday() {
        assertEquals(0, dayNavNewer(1))
        assertEquals(4, dayNavNewer(5))
        // Already on today - newer can't go to a future day.
        assertEquals(0, dayNavNewer(0))
    }

    @Test fun canGoNewerOnlyWhenNotOnToday() {
        assertFalse(dayNavCanGoNewer(0))
        assertTrue(dayNavCanGoNewer(1))
        assertTrue(dayNavCanGoNewer(30))
    }

    // ── swipe → offset ──────────────────────────────────────────────────────────

    private val threshold = 64f

    @Test fun swipeBelowThresholdIsNoOp() {
        assertEquals(3, dayNavSwipeTarget(3, dragX = 10f, thresholdPx = threshold))
        assertEquals(3, dayNavSwipeTarget(3, dragX = -63.9f, thresholdPx = threshold))
        assertEquals(0, dayNavSwipeTarget(0, dragX = 0f, thresholdPx = threshold))
    }

    @Test fun rightwardSwipeGoesOlder() {
        // A rightward (positive) swipe reveals the past - older day.
        assertEquals(1, dayNavSwipeTarget(0, dragX = 120f, thresholdPx = threshold))
        assertEquals(6, dayNavSwipeTarget(5, dragX = 200f, thresholdPx = threshold))
    }

    @Test fun leftwardSwipeGoesNewerClampedAtToday() {
        assertEquals(4, dayNavSwipeTarget(5, dragX = -120f, thresholdPx = threshold))
        // On today a leftward swipe can't move past today.
        assertEquals(0, dayNavSwipeTarget(0, dragX = -300f, thresholdPx = threshold))
    }

    @Test fun swipeExactlyAtThresholdCounts() {
        // |drag| < threshold is a no-op; == threshold is a real swipe (the boundary belongs to the swipe).
        assertEquals(1, dayNavSwipeTarget(0, dragX = threshold, thresholdPx = threshold))
        assertEquals(0, dayNavSwipeTarget(1, dragX = -threshold, thresholdPx = threshold))
    }
}
