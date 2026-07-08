package com.noop.analytics

// DisplayTrace.kt - Kotlin twin of DisplayTrace.swift. Pure values + line formatters for the Display &
// Performance test mode: the device-metrics summary, the rolling frame-time / hitch summary, and the
// memory high-water line, plus the tagged-tail parsers for the deviceMetricsNow / frameSummaryNow ids.
// No state, no IO, no em-dashes. Byte-aligned with the Swift line shapes so a shared report reads
// identically on either platform.

/**
 * A platform-resolved snapshot of the display environment (Kotlin twin of the Swift DisplayMetrics).
 * Every field is already read by the caller (the Android Configuration / window insets), so this type is
 * pure data and the formatter below has no platform dependency. Nullable fields are for metrics a platform
 * cannot offer; the formatter prints "n/a" for a null, never fabricating a value.
 */
data class DisplayMetrics(
    val horizontalSizeClass: String?,
    val verticalSizeClass: String?,
    val widthPt: Double,
    val heightPt: Double,
    val scale: Double,
    val safeTop: Double,
    val safeBottom: Double,
    val safeLeading: Double,
    val safeTrailing: Double,
    val dynamicType: String?,
    val orientation: String,
    val theme: String,
)

/**
 * A platform-resolved snapshot of the on-device DATA VOLUME (CAPTURE-D / #797), the Kotlin twin of the
 * Swift DataVolume: the read-set that backs the screens, so an import-driven-lag report shows what it is
 * rendering over, not just frame stats. Every count is already read from the STORE by the caller (never via
 * the reactive view-model caches), so this type is pure data and the formatter has no store dependency.
 */
data class DataVolume(
    /** Total raw stream rows in the store (HR + RR + events + the biometric streams), the dominant cost. */
    val dbRows: Int,
    /** Number of distinct days that carry IMPORTED daily metrics (the #799 import surface). */
    val importedDays: Int,
    /** Total detected/recorded workout rows. */
    val workouts: Int,
    /** Rows touched by the most recent render the caller measured, or null when it hasn't measured one. */
    val lastRenderRows: Int?,
)

object DisplayTrace {

    /** The data-volume line (CAPTURE-D / #797): one upfront DISPLAY summary of the store's read-set, so a
     *  "feels laggy after import" report shows HOW MUCH data the screens render over (db rows, imported
     *  days, workouts, last render's row count), not only frame timings. A null lastRenderRows (no render
     *  measured yet) prints "n/a" rather than fabricating a 0. Byte-identical to the Swift formatter. */
    fun dataVolumeLine(v: DataVolume): String {
        val last = v.lastRenderRows?.toString() ?: "n/a"
        return "dataVolume dbRows=${v.dbRows} importedDays=${v.importedDays} " +
            "workouts=${v.workouts} lastRenderRows=$last"
    }

    /** The device-metrics line: one upfront DISPLAY summary of the resolved DisplayMetrics, so a "screen
     *  looks wrong" report carries the exact layout environment. Whole-point rounding; a null size class /
     *  Dynamic Type prints "n/a". Mirrors the Swift formatter exactly. */
    fun deviceMetricsLine(m: DisplayMetrics): String {
        val h = m.horizontalSizeClass ?: "n/a"
        val v = m.verticalSizeClass ?: "n/a"
        val dt = m.dynamicType ?: "n/a"
        return "deviceMetrics " +
            "size=${pt(m.widthPt)}x${pt(m.heightPt)}pt @${scaleLabel(m.scale)}x " +
            "sizeClass=$h/$v " +
            "safeArea=t${pt(m.safeTop)} b${pt(m.safeBottom)} l${pt(m.safeLeading)} r${pt(m.safeTrailing)} " +
            "dynamicType=$dt orientation=${m.orientation} theme=${m.theme}"
    }

    /** The rolling frame-time / hitch summary line: a periodic digest (NOT a per-frame line) of the frame
     *  monitor's last window. Mirrors the Swift formatter. */
    fun frameSummaryLine(
        frames: Int, meanMs: Double, p95Ms: Double, hitches: Int, worstMs: Double, hitchThresholdMs: Double,
    ): String =
        "frameSummary frames=$frames mean=${ms(meanMs)}ms p95=${ms(p95Ms)}ms " +
            "hitches=$hitches worst=${ms(worstMs)}ms threshold=${ms(hitchThresholdMs)}ms"

    /** The memory high-water line: the peak resident footprint (MB) seen while the mode was active.
     *  Mirrors the Swift formatter. */
    fun memoryHighWaterLine(peakMB: Double): String = "memoryHighWater peak=${ms(peakMB)}MB"

    /** Round a point value to a whole number; negatives clamp to 0 (an inset is never negative). Mirrors
     *  the Swift helper (Int(rounded())). */
    internal fun pt(v: Double): String = maxOf(0.0, v).let { Math.round(it).toInt().toString() }

    /** Backing scale to one decimal; "?" when the caller could not read it (0). Mirrors the Swift helper. */
    internal fun scaleLabel(v: Double): String = if (v > 0) oneDecimal(v) else "?"

    /** Millisecond / MB value to one decimal, clamped at 0, matching the Swift `%.1f`. */
    internal fun ms(v: Double): String = oneDecimal(maxOf(0.0, v))

    /** Locale-stable one-decimal format so the line reads identically everywhere (the Swift `%.1f` is
     *  locale-independent; String.format with Locale.US matches it). */
    private fun oneDecimal(v: Double): String = String.format(java.util.Locale.US, "%.1f", v)
}

/**
 * Pure values for the Display & Performance live-readout panel (Kotlin twin of the Swift DisplayReadout).
 * Each parses the DISPLAY-tagged log tail the emitters write. No state, no IO, no em-dashes.
 */
object DisplayReadout {

    /** The most recent device-metrics summary for the `deviceMetricsNow` id: everything after the
     *  "deviceMetrics " marker on the last device-metrics line. null when none yet. Mirrors the Swift parser. */
    fun deviceMetricsNow(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val i = line.indexOf("deviceMetrics ")
            if (i >= 0) {
                val frag = line.substring(i + "deviceMetrics ".length).trim()
                if (frag.isNotEmpty()) return frag
            }
        }
        return null
    }

    /** The most recent frame-summary fragment for an at-a-glance perf read, or null when the frame monitor
     *  has not yet emitted a window. Mirrors the Swift parser. */
    fun frameSummaryNow(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val i = line.indexOf("frameSummary ")
            if (i >= 0) {
                val frag = line.substring(i + "frameSummary ".length).trim()
                if (frag.isNotEmpty()) return frag
            }
        }
        return null
    }
}
