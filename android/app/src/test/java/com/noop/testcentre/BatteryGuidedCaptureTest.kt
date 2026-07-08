package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Test

/** Twin of the Swift BatteryGuidedCaptureTests: same day-count boundaries (#713, Test Centre).
 *  No em-dashes. */
class BatteryGuidedCaptureTest {

    private val day = 86_400_000L   // ms

    @Test fun statusCountsElapsedDaysAgainstTarget() {
        // started at epoch 0 ms; 1h in -> day 1 of 3.
        assertEquals("Capturing day 1 of 3",
            BatteryGuidedCapture.statusText(startedAtMs = 0L, target = 3, nowMs = 3_600_000L))
        // 2 full days in -> day 3 of 3.
        assertEquals("Capturing day 3 of 3",
            BatteryGuidedCapture.statusText(startedAtMs = 0L, target = 3, nowMs = 2 * day + 3_600_000L))
        // Past the window -> done.
        assertEquals("Capture complete, 3 of 3 days",
            BatteryGuidedCapture.statusText(startedAtMs = 0L, target = 3, nowMs = 3 * day))
    }

    @Test fun statusNullStartIsNotStarted() {
        assertEquals("Not started",
            BatteryGuidedCapture.statusText(startedAtMs = null, target = 3, nowMs = 100L))
    }
}
