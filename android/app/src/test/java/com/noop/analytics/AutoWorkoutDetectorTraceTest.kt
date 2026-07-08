package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Twin of the Swift AutoWorkoutDetectorTraceTests: the Workouts & GPS test mode's pure traces. Proves the
 * auto-detect trace returns the SAME List<DetectedWorkout> detect(...) does (byte-identical) AND names why
 * each window was offered or dropped, plus the WorkoutsTrace line formatters and the WorkoutsReadout parser.
 * No em-dashes. Pure-JVM, no Robolectric / Mockito.
 */
class AutoWorkoutDetectorTraceTest {

    private val dev = "test-device"
    private fun hr(ts: Long, bpm: Int) = HrSample(deviceId = dev, ts = ts, bpm = bpm)
    private fun grav(ts: Long, x: Double) = GravitySample(deviceId = dev, ts = ts, x = x, y = 0.0, z = 1.0)
    private fun block(start: Long, durS: Int, bpm: Int): List<HrSample> =
        (0 until durS).map { hr(start + it, bpm) }

    @Test fun traceResultsAreByteIdenticalToDetect() {
        val start = 1_000_000L
        val durS = 20 * 60
        val hr = block(start - 600, 600, 65) + block(start, durS, 120) + block(start + durS, 600, 65)
        val plain = AutoWorkoutDetector.detect(hr, restingHR = 60)
        val (traced, lines) = AutoWorkoutDetectorTrace.detectTrace(hr, restingHR = 60)
        assertEquals(plain, traced)
        assertEquals(1, traced.size)
        assertTrue(lines.any { it.startsWith("autoDetect path=autoDetect hrSamples=") })
        assertTrue(lines.any { it.contains("autoDetect thresholds elevatedMargin=30bpm") })
        assertTrue(lines.any { it.contains("verdict=offered") })
        assertTrue(lines.any { it.contains("autoDetect result windows=1") })
        assertFalse(lines.any { it.contains("\u2014") })
    }

    @Test fun traceNamesNoSustainedSpan() {
        val hr = block(1_000_000L, 1_800, 65) // all rest, never above the floor
        val (traced, lines) = AutoWorkoutDetectorTrace.detectTrace(hr, restingHR = 60)
        assertTrue(traced.isEmpty())
        assertTrue(lines.any { it.contains("why=noSustainedSpan") })
        assertTrue(lines.any { it.contains("result windows=0") })
    }

    @Test fun traceNamesSavedOverlapDrop() {
        val start = 1_000_000L
        val durS = 20 * 60
        val hr = block(start, durS, 120)
        val saved = listOf((start - 60) to (start + durS + 60))
        val plain = AutoWorkoutDetector.detect(hr, restingHR = 60, savedWorkouts = saved)
        val (traced, lines) = AutoWorkoutDetectorTrace.detectTrace(hr, restingHR = 60, savedWorkouts = saved)
        assertEquals(plain, traced)
        assertTrue(traced.isEmpty())
        assertTrue(lines.any { it.contains("verdict=dropped why=overlapsSavedWorkout") })
    }

    @Test fun traceNamesMotionNotConfirmed() {
        val start = 1_000_000L
        val durS = 20 * 60
        val hr = block(start, durS, 120)
        // A flat (no-motion) gravity series → motion-confirm gate drops the window.
        val gravity = (0 until durS).map { grav(start + it, 0.0) }
        val plain = AutoWorkoutDetector.detect(hr, restingHR = 60, gravity = gravity)
        val (traced, lines) = AutoWorkoutDetectorTrace.detectTrace(hr, restingHR = 60, gravity = gravity)
        assertEquals(plain, traced)
        assertTrue(traced.isEmpty())
        assertTrue(lines.any { it.contains("verdict=dropped why=motionNotConfirmed") })
    }

    @Test fun workoutsTraceLineShapes() {
        assertEquals(
            "session event=start sport=running hrSamples=0",
            WorkoutsTrace.sessionLine(event = "start", sportKey = "running", hrSamples = 0),
        )
        assertEquals(
            "session event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240",
            WorkoutsTrace.sessionLine(
                event = "end", sportKey = "running", hrSamples = 1200, durationSec = 1260, gpsPoints = 240,
            ),
        )
        assertEquals(
            "gps rawFixes=250 accepted=240 distanceM=5013 (filter: accuracy+speed gate)",
            WorkoutsTrace.gpsLine(rawFixes = 250, acceptedPoints = 240, distanceM = 5012.6),
        )
        assertEquals(
            "dedup sport=running kept=strap(richness=5) dropped=apple(richness=1) (same activity, richer kept)",
            WorkoutsTrace.dedupLine(
                sportKey = "running", keptSource = "strap", droppedSource = "apple",
                keptRichness = 5, droppedRichness = 1,
            ),
        )
        // #975: the engine detected-bout decision line , persisted (no overlap) and dropped (overlaps a real).
        assertEquals(
            "detectedBout verdict=persisted durMin=42 avgBpm=148",
            WorkoutsTrace.detectedBoutLine(verdict = "persisted", durMin = 42, avgBpm = 148),
        )
        assertEquals(
            "detectedBout verdict=droppedOverlap durMin=42 avgBpm=148 overlapSource=manual",
            WorkoutsTrace.detectedBoutLine(
                verdict = "droppedOverlap", durMin = 42, avgBpm = 148, overlapSource = "manual",
            ),
        )
    }

    @Test fun workoutsReadoutParsesLastSession() {
        val tail = listOf(
            "[workouts] session event=start sport=running hrSamples=0",
            "[workouts] session event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240",
        )
        assertEquals(
            "event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240",
            WorkoutsReadout.lastSessionSummary(tail),
        )
        assertNull(WorkoutsReadout.lastSessionSummary(emptyList()))
    }
}
