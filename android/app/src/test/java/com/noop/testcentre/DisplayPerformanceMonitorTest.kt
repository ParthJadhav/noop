package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Proves the Display & Performance monitor's CRITICAL property and its pure pieces on the plain JVM (no
 * Robolectric / Mockito / Choreographer). The Android-only frame callback wiring is never invoked here;
 * only the pure window stats, the font-scale label, and the off-state contract are exercised. The Swift
 * DisplayPerformanceTests pins the same window-stats numbers and the lifecycle emission.
 */
class DisplayPerformanceMonitorTest {

    // The critical property: the monitor is NOT running until start() is called. Because start() requires
    // a Choreographer (the main looper, unavailable on the JVM), it is never started here, so isRunning
    // must read false - the same "zero-cost when off, no callback posted" guarantee the screen relies on.
    @Test
    fun isNotRunningUntilStarted() {
        DisplayPerformanceMonitor.stop() // defensive: a previous test cannot leave it running
        assertFalse(
            "the frame monitor must not be running until the Display mode starts it",
            DisplayPerformanceMonitor.isRunning,
        )
    }

    @Test
    fun stopWhileNotRunningIsInert() {
        // A defensive stop() on a never-started monitor must be a no-op (it would otherwise NPE on the
        // Choreographer / emit a stray line). isRunning stays false.
        DisplayPerformanceMonitor.stop()
        DisplayPerformanceMonitor.stop()
        assertFalse(DisplayPerformanceMonitor.isRunning)
    }

    @Test
    fun windowStatsMeanAndP95() {
        // 19 frames at 16 ms and one 100 ms hitch: mean is pulled up a little, p95 (nearest-rank) is the hitch.
        val durations = List(19) { 16.0 } + 100.0
        val (mean, p95) = DisplayPerformanceMonitor.windowStats(durations)
        assertEquals((16.0 * 19 + 100.0) / 20.0, mean, 0.001)
        assertEquals(100.0, p95, 0.001)
    }

    @Test
    fun windowStatsEmptyIsZero() {
        val (mean, p95) = DisplayPerformanceMonitor.windowStats(emptyList())
        assertEquals(0.0, mean, 0.0)
        assertEquals(0.0, p95, 0.0)
    }

    @Test
    fun fontScaleLabelTwoDecimalsLocaleStable() {
        assertEquals("1.00", DisplayPerformanceMonitor.fontScaleLabel(1.0f))
        assertEquals("1.30", DisplayPerformanceMonitor.fontScaleLabel(1.3f))
        assertEquals("1.50", DisplayPerformanceMonitor.fontScaleLabel(1.5f))
    }
}
