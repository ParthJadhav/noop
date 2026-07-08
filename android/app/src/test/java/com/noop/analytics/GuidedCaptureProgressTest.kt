package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class GuidedCaptureProgressTest {
    @Test fun capturing() {
        assertEquals(GuidedCaptureProgress.Capturing(2, 3),
            GuidedCaptureProgress.evaluate(target = 3, nightsWithData = 2, nightsElapsed = 2))
    }
    @Test fun gapNight() {
        assertEquals(GuidedCaptureProgress.Capturing(1, 3),
            GuidedCaptureProgress.evaluate(target = 3, nightsWithData = 1, nightsElapsed = 3))
    }
    @Test fun complete() {
        assertEquals(GuidedCaptureProgress.Complete,
            GuidedCaptureProgress.evaluate(target = 3, nightsWithData = 3, nightsElapsed = 3))
    }
    @Test fun completeWhenOverTarget() {
        assertEquals(GuidedCaptureProgress.Complete,
            GuidedCaptureProgress.evaluate(target = 3, nightsWithData = 4, nightsElapsed = 5))
    }
    @Test fun labels() {
        assertEquals("Capture complete. Tap Report to export.",
            GuidedCaptureProgress.label(GuidedCaptureProgress.Complete))
        assertEquals("Captured 1 of 3 nights. Wear it again tonight.",
            GuidedCaptureProgress.label(GuidedCaptureProgress.Capturing(1, 3)))
        assertEquals("No data last night. Wear the strap tonight to continue.",
            GuidedCaptureProgress.gapNudge())
    }
    @Test fun noEmDash() {
        assertFalse(GuidedCaptureProgress.label(GuidedCaptureProgress.Capturing(1, 3)).contains("\u2014"))
    }
}
