package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample

// AutoWorkoutDetectorTrace.kt - Kotlin twin of AutoWorkoutDetector+Trace.swift. The Workouts & GPS
// test-mode auto-detect trace + line formatters.
//
// detectTrace(...) is the side-effect-free twin of AutoWorkoutDetector.detect(...): it returns the SAME
// List<DetectedWorkout> detect would (it reuses detect verbatim), plus a trace that names the detector's
// inputs (HR sample count, resting floor), the thresholds it applied, and WHY each candidate window was
// offered or dropped (too short, motion-not-confirmed, overlaps a saved session). So a "workout went
// missing / auto-detect didn't fire" report shows exactly which gate kept or dropped each window.
//
// WorkoutsTrace adds the line formatters the app emitters use for the session lifecycle, the GPS-fix count
// and the cross-source dedup decisions. WorkoutsReadout parses the WORKOUTS-tagged log tail back into the
// lastSessionSummary id. Everything is pure, no clock, no IO, no PII. Byte-aligned with the Swift line
// shapes so a shared report reads identically on either platform. No em-dashes.

object AutoWorkoutDetectorTrace {

    /**
     * Side-effect-free diagnostic twin of [AutoWorkoutDetector.detect]: returns the SAME
     * List<DetectedWorkout> detect would (it reuses detect verbatim), plus the trace. The trace logs the
     * inputs + thresholds, then walks the detector's own gates (sustained-minutes, motion-confirm,
     * saved-overlap) to name why each merged window survived or dropped, mirroring the algorithm exactly.
     * Mirrors the Swift AutoWorkoutDetector.detectTrace. [path] tags the entry point.
     */
    fun detectTrace(
        hr: List<HrSample>,
        restingHR: Int? = null,
        gravity: List<GravitySample> = emptyList(),
        savedWorkouts: List<Pair<Long, Long>> = emptyList(),
        path: String = "autoDetect",
    ): Pair<List<AutoWorkoutDetector.DetectedWorkout>, List<String>> {
        // The result the Today card reads, verbatim, so the trace cannot diverge from it.
        val results = AutoWorkoutDetector.detect(hr, restingHR, gravity, savedWorkouts)

        val lines = ArrayList<String>()
        val floor = (restingHR ?: AutoWorkoutDetector.defaultRestingHR) + AutoWorkoutDetector.elevatedMarginBPM
        val hasMotion = gravity.isNotEmpty()

        lines.add(
            "autoDetect path=$path hrSamples=${hr.size} " +
                "restingBpm=${restingHR?.toString() ?: "default(${AutoWorkoutDetector.defaultRestingHR})"} " +
                "elevatedFloor=${floor}bpm motion=${if (hasMotion) "supplied" else "hrOnly"} " +
                "savedSpans=${savedWorkouts.size}",
        )
        lines.add(
            "autoDetect thresholds elevatedMargin=${AutoWorkoutDetector.elevatedMarginBPM}bpm " +
                "minSustainedMin=${AutoWorkoutDetector.minSustainedMin} maxDipS=${AutoWorkoutDetector.maxDipS} " +
                "mergeGapS=${AutoWorkoutDetector.mergeGapS} motionConfirmMean=${AutoWorkoutDetector.motionConfirmMean}",
        )

        // Rebuild the SAME merged windows the detector forms (steps 1-4), to name each verdict (steps 5-6).
        val seg = hr.sortedBy { it.ts }
        if (seg.isEmpty()) {
            lines.add("autoDetect result windows=0 (no HR samples)")
            return results to lines
        }

        val spans = ArrayList<Pair<Long, Long>>()
        var spanStart: Long? = null
        var spanEnd = 0L
        var dipStart: Long? = null
        fun closeSpan() {
            val s = spanStart
            if (s != null && (spanEnd - s) >= AutoWorkoutDetector.minSustainedMin * 60.0) spans.add(s to spanEnd)
            spanStart = null
            dipStart = null
        }
        for (sample in seg) {
            if (sample.bpm >= floor) {
                if (spanStart == null) spanStart = sample.ts
                spanEnd = sample.ts
                dipStart = null
            } else if (spanStart != null) {
                val d = dipStart ?: sample.ts.also { dipStart = it }
                if ((sample.ts - d) > AutoWorkoutDetector.maxDipS) closeSpan()
            }
        }
        closeSpan()

        if (spans.isEmpty()) {
            lines.add(
                "autoDetect why=noSustainedSpan " +
                    "(no contiguous run held >=${AutoWorkoutDetector.minSustainedMin}min above ${floor}bpm)",
            )
            lines.add("autoDetect result windows=0")
            return results to lines
        }

        val merged = ArrayList<Pair<Long, Long>>()
        var curStart = spans[0].first
        var curEnd = spans[0].second
        for (k in 1 until spans.size) {
            val next = spans[k]
            if ((next.first - curEnd) < AutoWorkoutDetector.mergeGapS) {
                curEnd = maxOf(curEnd, next.second)
            } else {
                merged.add(curStart to curEnd)
                curStart = next.first
                curEnd = next.second
            }
        }
        merged.add(curStart to curEnd)

        // Per-window verdict (the autoDetectWhy capture), mirroring detect steps 5-6. The motion series is
        // built the SAME way detect does (motionIntensityByTs), so the mean comparison matches exactly.
        val motion = if (hasMotion) AutoWorkoutDetector.motionIntensityByTs(gravity) else emptyMap()
        for ((start, end) in merged) {
            val durMin = ((end - start) / 60L).toInt()
            if (savedWorkouts.any { AutoWorkoutDetector.overlaps(start, end, it.first, it.second) }) {
                lines.add("autoDetect window durMin=$durMin verdict=dropped why=overlapsSavedWorkout")
                continue
            }
            if (motion.isNotEmpty()) {
                val inWin = motion.entries.filter { it.key in start..end }.map { it.value }
                val meanMotion = if (inWin.isEmpty()) 0.0 else inWin.sum() / inWin.size.toDouble()
                if (meanMotion < AutoWorkoutDetector.motionConfirmMean) {
                    lines.add(
                        "autoDetect window durMin=$durMin verdict=dropped why=motionNotConfirmed " +
                            "(mean=${Math.round(meanMotion * 1000.0) / 1000.0} < ${AutoWorkoutDetector.motionConfirmMean})",
                    )
                    continue
                }
            }
            lines.add("autoDetect window durMin=$durMin verdict=offered")
        }
        lines.add(
            "autoDetect result windows=${results.size} " +
                "(offered the most recent that is not saved or dismissed)",
        )
        return results to lines
    }
}

/**
 * Pure line formatters + the live-readout parser for the Workouts & GPS test mode. Kotlin twin of the Swift
 * WorkoutsTrace / WorkoutsReadout. The app emitters own the live state; these own the line SHAPE so both
 * platforms read identically. No state, no IO, no PII. No em-dashes.
 */
object WorkoutsTrace {

    /** A session-lifecycle line. [event] is "start" / "end" / "discarded"; the counts are the captured HR
     *  window size and (for an end) the duration + accepted GPS points. Sport is the normalised key. */
    fun sessionLine(
        event: String,
        sportKey: String,
        hrSamples: Int,
        durationSec: Int? = null,
        gpsPoints: Int? = null,
    ): String {
        val sb = StringBuilder("session event=$event sport=$sportKey hrSamples=$hrSamples")
        if (durationSec != null) sb.append(" durationSec=$durationSec")
        if (gpsPoints != null) sb.append(" gpsPoints=$gpsPoints")
        return sb.toString()
    }

    /**
     * A GPS-fix-progress line: raw fixes seen, how many the filter accepted, and the running distance.
     *
     * [rawFixes] is OPTIONAL: macOS sees the pre-filter raw stream and passes a real count so the line shows
     * a true accept rate. Android's LocationTracker pre-filters upstream, so the raw count is NOT available
     * at the GpsSession seam (every fix here is already accepted); it passes null and the line renders
     * `rawFixes=n/a` rather than implying an accept rate the platform cannot measure. Mirrors Swift gpsLine.
     */
    fun gpsLine(rawFixes: Int?, acceptedPoints: Int, distanceM: Double): String =
        "gps rawFixes=${rawFixes?.toString() ?: "n/a"} accepted=$acceptedPoints " +
            "distanceM=${Math.round(distanceM)} (filter: accuracy+speed gate)"

    /** A cross-source dedup decision line: two same-activity rows collapsed to the richer one. */
    fun dedupLine(
        sportKey: String,
        keptSource: String,
        droppedSource: String,
        keptRichness: Int,
        droppedRichness: Int,
    ): String =
        "dedup sport=$sportKey kept=$keptSource(richness=$keptRichness) " +
            "dropped=$droppedSource(richness=$droppedRichness) (same activity, richer kept)"

    /**
     * An engine detected-bout decision line (#975): the IntelligenceEngine derives a bout from raw HR then
     * either PERSISTS it (source "-noop", sport "detected") or DROPS it because it overlaps a real logged
     * session (manual / imported), so the same bout is never counted twice. `verdict` is "persisted" /
     * "droppedOverlap" / "droppedShadow"; `durMin` is the whole-minute bout length; on a drop, `overlapSource`
     * names the real row it collided with. No PII (a source label + minutes + bpm only). Swift twin
     * AutoWorkoutDetector.detectedBoutLine.
     */
    fun detectedBoutLine(
        verdict: String,
        durMin: Int,
        avgBpm: Int,
        overlapSource: String? = null,
    ): String {
        var line = "detectedBout verdict=$verdict durMin=$durMin avgBpm=$avgBpm"
        if (overlapSource != null) line += " overlapSource=$overlapSource"
        return line
    }
}

/**
 * Pure values for the Workouts & GPS live-readout panel. Kotlin twin of the Swift WorkoutsReadout. Parses
 * the WORKOUTS-tagged log tail the emitters write. No state, no IO, no em-dashes. (Android defers the Compose
 * readout panel for ALL modes, matching the existing split; this twin exists for parity + tests.)
 */
object WorkoutsReadout {

    /** The last session summary for the `lastSessionSummary` id: the most recent session-lifecycle line's
     *  fragment, or null when none is present. */
    fun lastSessionSummary(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val i = line.indexOf("session ")
            if (i >= 0) {
                val frag = line.substring(i + "session ".length).trim()
                if (frag.isNotEmpty()) return frag
            }
        }
        return null
    }
}
