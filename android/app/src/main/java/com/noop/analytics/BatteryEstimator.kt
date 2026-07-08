package com.noop.analytics

import java.util.Locale
import kotlin.math.roundToLong

/**
 * "~X days left" for a strap, worked out from its battery state-of-charge (SoC) history (#713). Neither
 * the WHOOP app nor WHOOP's API ever give you a runtime estimate, but NOOP already banks a SoC time
 * series from the strap over BLE, so no manual logging is needed. We fit the recent DISCHARGE slope and
 * divide the current charge by it. When the discharge run is too short or too flat to trust, we fall back
 * to the device's typical full-charge life for its generation.
 *
 * The measured slope already bakes in how the user actually runs their strap (HR broadcast, strain,
 * recording), so there are no hand-tuned usage multipliers. The discharge curve IS the personalisation.
 *
 * Honest about the limits: battery drain is non-linear (faster near full and near empty) and the strap
 * reports SoC sparsely, so this is an estimate, not a guarantee. Behaviour-identical twin of the Swift
 * BatteryEstimator (same fixtures, same numbers).
 */
object BatteryEstimator {

    /** Typical full-charge life in hours per WHOOP generation, used before enough of the user's own
     *  discharge has been seen to fit a slope. WHOOP 4.0 is about 4.5 days, WHOOP 5.0 / MG about 12 days
     *  (the figures cited in #713). The caller maps its connected strap to one of these. */
    const val ratedLifeHoursWhoop4 = 108.0   // 4.5 days
    const val ratedLifeHoursWhoop5 = 288.0   // 12 days

    /** A discharge run has to span at least this long AND drop at least this much before its measured
     *  slope is trusted over the rated fallback. Short or noisy spans produce wild rates. */
    const val minSpanHours = 2.0
    const val minDropPct = 2.0

    /** A SoC rise larger than this (percentage points) between two consecutive readings marks a CHARGE.
     *  The discharge run restarts after it, so we never fit a rate across a charge. */
    const val chargeStepPct = 1.0

    /** A charge only ANCHORS a fresh discharge run when it returns the strap NEAR FULL (#8). A mere partial
     *  top-up (e.g. 40% -> 55% on a quick desk charge) used to reset the run exactly like a 0% -> 100%
     *  charge, discarding the long clean discharge history before it and inflating "days left" off the short
     *  post-top-up tail. So a rise is treated as a run-reset anchor only when the post-rise SoC reaches this;
     *  a partial top-up is instead stepped over, and the fit prefers the longer pre-top-up discharge segment. */
    const val nearFullPct = 90.0

    /** Where the drain rate came from: the user's own measured discharge, or the rated fallback. */
    enum class Source { MEASURED, RATED }

    data class Estimate(
        /** Estimated hours of runtime left at the latest reading. */
        val remainingHours: Double,
        val source: Source,
        /** The latest SoC the estimate is anchored to, in percent. */
        val currentSoc: Double,
    ) {
        /** Convenience for callers that just want the days figure. */
        val daysRemaining: Double get() = remainingHours / 24
        /** Mirror so callers can read either name. */
        val hoursRemaining: Double get() = remainingHours
    }

    /**
     * Estimate remaining runtime from a SoC series.
     *
     * [samples] = (unix-seconds, SoC%) pairs in any order. The caller drops nil-SoC rows and maps the
     * banked battery series into this shape. [ratedHours] = the strap's typical full-charge life, one of
     * the `ratedLifeHours…` constants, chosen by the caller from the connected strap's generation.
     * Returns null only when there isn't a single reading to anchor to. Mirrors the Swift estimate().
     */
    fun estimate(samples: List<Pair<Long, Double>>, ratedHours: Double): Estimate? {
        val sorted = samples.sortedBy { it.first }
        val last = sorted.lastOrNull() ?: return null
        val current = last.second

        // The discharge segment whose slope we fit: anchored at the most recent NEAR-FULL charge, and ending
        // before any later partial top-up, so neither a charge earlier in the buffer nor a quick desk top-up
        // distorts the fitted slope (#8).
        val dischargeRun = dischargeFitWindow(sorted)

        // Fit the discharge slope over the segment as a simple endpoints rate (%/h). The series is short and
        // monotone-ish within a segment, so endpoints are as good as a least-squares line and far cheaper,
        // and they keep the test fixtures exact. null when it's too short, too flat, or not discharging. The
        // estimate stays anchored to `current` (the latest SoC), even when the fit window ends earlier.
        val measuredRate: Double? = run {
            if (dischargeRun.size < 2) return@run null
            val first = dischargeRun.first()
            val lastRun = dischargeRun.last()
            val spanHours = (lastRun.first - first.first) / 3600.0
            val drop = first.second - lastRun.second
            if (spanHours < minSpanHours || drop < minDropPct) return@run null
            val rate = drop / spanHours
            if (rate > 0) rate else null
        }

        val rate = measuredRate ?: (100.0 / maxOf(ratedHours, 1.0))
        val remaining = maxOf(0.0, current) / rate
        // A fresh full charge can't realistically beat about 1.5x the rated life, so clamp out any wild
        // estimate from a near-flat measured run that still squeaked past the drop gate.
        val clamped = minOf(remaining, ratedHours * 1.5)
        return Estimate(clamped, if (measuredRate != null) Source.MEASURED else Source.RATED, current)
    }

    /**
     * The slice of the sorted SoC series whose endpoints we fit the discharge slope on (#8). Two rules,
     * both keyed off "is this rise a real charge or a partial top-up":
     *  1. START at the most recent NEAR-FULL charge: the most recent rise > chargeStepPct that LANDS at
     *     >= nearFullPct. A partial top-up (rise that doesn't reach near-full) is NOT an anchor: the scan
     *     steps over it and keeps looking further back, so a quick 40->55 desk charge no longer throws away
     *     the long clean discharge before it. If there is no near-full charge in the buffer, start = 0.
     *  2. END before the most recent partial top-up that falls AFTER the start anchor (a rise > chargeStepPct
     *     that does NOT reach near-full), so the fitted slope is the longer pre-top-up discharge segment,
     *     never the short, slope-flattening post-top-up tail.
     * `current` (the latest SoC the estimate is anchored to) is taken by the caller from the series end, not
     * from this window, so trimming the tail changes only the slope, never the SoC the runtime divides into.
     * Pure; the Swift twin is `dischargeFitWindow`.
     */
    fun dischargeFitWindow(sorted: List<Pair<Long, Double>>): List<Pair<Long, Double>> {
        if (sorted.size < 2) return sorted

        // 1. Most recent NEAR-FULL charge anchors the run start; partial top-ups are stepped over.
        var startIdx = 0
        for (i in sorted.size - 1 downTo 1) {
            if (sorted[i].second > sorted[i - 1].second + chargeStepPct && sorted[i].second >= nearFullPct) {
                startIdx = i
                break
            }
        }

        // 1b. #919: with no near-full (>=90%) charge to anchor on - common on a 12-day WHOOP 5.0 that rarely
        //     tops past 90% between charges - anchor at the buffer's HIGHEST SoC (the top of the most recent
        //     discharge) rather than the oldest reading, which can sit below a later charge and net to a
        //     NON-discharge window (drop < 0 -> stuck on rated). The max is >= every later reading, so the
        //     window can only discharge; the >=minDropPct gate still rejects a flat run. Preserves #8: its
        //     buffer starts at the max, so this stays index 0 there. Last occurrence of the max (>=).
        if (startIdx == 0) {
            var maxIdx = 0
            for (i in sorted.indices) if (sorted[i].second >= sorted[maxIdx].second) maxIdx = i
            startIdx = maxIdx
        }

        // 2. End before the most recent PARTIAL top-up after the start anchor (a rise > chargeStepPct that
        //    does NOT reach near-full), so the fit prefers the longer pre-top-up discharge segment.
        var endIdx = sorted.size - 1
        if (endIdx - startIdx >= 1) {
            for (i in sorted.size - 1 downTo startIdx + 1) {
                if (sorted[i].second > sorted[i - 1].second + chargeStepPct && sorted[i].second < nearFullPct) {
                    endIdx = i - 1
                    break
                }
            }
        }
        if (endIdx <= startIdx) return sorted.subList(startIdx, sorted.size)
        return sorted.subList(startIdx, endIdx + 1)
    }

    /**
     * Side-effect-free diagnostic twin of [estimate]: returns the SAME Estimate plus a list of trace
     * lines describing the full (t, soc) series, the detected charge step(s), the trailing discharge run
     * start/span/drop, the fitted slope, and which gate (minSpanHours / minDropPct) decided source =
     * measured vs rated. The Battery test mode gates this behind TestCentre.active(BATTERY); when the mode
     * is off it is never called, so there is zero cost. Pure: no clock, no I/O. Twin of the Swift trace.
     */
    fun estimateTrace(samples: List<Pair<Long, Double>>, ratedHours: Double):
        Pair<Estimate?, List<String>> {
        val sorted = samples.sortedBy { it.first }
        val last = sorted.lastOrNull()
        val first0 = sorted.firstOrNull()
        if (last == null || first0 == null) {
            return null to listOf("battery series=0 readings, no reading to anchor to")
        }
        val lines = mutableListOf<String>()
        lines.add("battery series=${sorted.size} readings span ${first0.first}..${last.first}s")
        for (s in sorted) lines.add("battery read t=${s.first}s soc=${soc(s.second)}")

        // The most recent NEAR-FULL charge anchors the run start (same scan as estimate, #8); a partial
        // top-up does NOT anchor and is reported separately below.
        var startIdx = 0
        if (sorted.size >= 2) {
            for (i in sorted.size - 1 downTo 1) {
                if (sorted[i].second > sorted[i - 1].second + chargeStepPct && sorted[i].second >= nearFullPct) {
                    startIdx = i
                    val rise = sorted[i].second - sorted[i - 1].second
                    lines.add("battery chargeStep at t=${sorted[i].first}s +${soc(rise)}pp " +
                        "(>chargeStepPct ${soc(chargeStepPct)})")
                    break
                }
            }
        }
        // The most recent PARTIAL top-up after the anchor (a rise that does NOT reach near-full): the fit
        // ends before it and prefers the longer pre-top-up discharge segment (#8).
        if (sorted.size >= 2 && startIdx < sorted.size - 1) {
            for (i in sorted.size - 1 downTo startIdx + 1) {
                if (sorted[i].second > sorted[i - 1].second + chargeStepPct && sorted[i].second < nearFullPct) {
                    val rise = sorted[i].second - sorted[i - 1].second
                    lines.add("battery partialTopUp at t=${sorted[i].first}s +${soc(rise)}pp " +
                        "(<nearFullPct ${soc(nearFullPct)}) -> fit pre-top-up segment")
                    break
                }
            }
        }
        val run = dischargeFitWindow(sorted)

        var spanPass = false
        var dropPass = false
        if (run.size >= 2) {
            val runFirst = run.first()
            val runLast = run.last()
            val spanHours = (runLast.first - runFirst.first) / 3600.0
            val drop = runFirst.second - runLast.second
            lines.add("battery dischargeRun start=${runFirst.first}s " +
                "span=${hrs(spanHours)}h drop=${soc(drop)}pp")
            spanPass = spanHours >= minSpanHours
            dropPass = drop >= minDropPct
            if (spanPass && dropPass && drop / spanHours > 0) {
                lines.add("battery slope=${slope(drop / spanHours)}pct/h fitted from run endpoints")
            }
        } else {
            lines.add("battery dischargeRun too short to fit (run=${run.size} readings)")
        }

        val measured = spanPass && dropPass && run.size >= 2 &&
            (run.first().second - run.last().second) /
            ((run.last().first - run.first().first) / 3600.0) > 0
        lines.add("battery gate minSpanHours ${hrs(minSpanHours)} " +
            "${if (spanPass) "PASS" else "FAIL"}, minDropPct ${soc(minDropPct)} " +
            "${if (dropPass) "PASS" else "FAIL"} -> source=${if (measured) "measured" else "rated"}")

        return estimate(samples, ratedHours) to lines
    }

    private fun soc(v: Double) = String.format(Locale.US, "%.1f", v)
    private fun hrs(v: Double) = String.format(Locale.US, "%.1f", v)
    private fun slope(v: Double) = String.format(Locale.US, "%.1f", v)

    /** Display rule from #713: hours under 48h ("~14h"), days above ("~4.5 days"). Unit text only, the UI
     *  adds the "left" / "remaining" copy. Locale-fixed so the tests stay stable. */
    fun label(hours: Double): String =
        if (hours < 48) "~${hours.roundToLong()}h"
        else "~${String.format(Locale.US, "%.1f", hours / 24)} days"
}
