package com.noop.analytics

import kotlin.math.abs
import kotlin.math.roundToLong

/*
 * RangeReport.kt — the data model for a shareable offline "trends report" over a date
 * range. Faithful Kotlin mirror of StrandAnalytics/RangeReport.swift. Keep the metric
 * set, the per-metric trend thresholds, the half-split, the trend mapping, and the
 * headline ranking byte-identical to Swift — cross-platform parity is the contract.
 *
 * Pure aggregation ONLY — there is NO rendering here. The UI layer builds the PDF/PNG
 * view from this struct; this file just turns sparse day→value series into a clean,
 * explainable set of per-metric range statistics.
 *
 * Pure, deterministic, DB-free. Given each metric's daily series as a Map<dayKey, Double>
 * (any metric may be missing, any day may be absent) and an inclusive [start, end]
 * "yyyy-MM-dd" range, this produces a RangeReport with, per metric that has at least one
 * value in range: n, mean, min/max (value + the day it fell on), first-half vs
 * second-half mean, a rising/falling/flat trend (OLS slope-per-day vs a small per-metric
 * threshold), and the latest value. Plus the range (start/end/totalDays) and a short
 * headline stat set.
 *
 * Day keys are the same "yyyy-MM-dd" strings AnalyticsEngine emits; lexicographic order
 * IS chronological order for zero-padded ISO days, so we sort/compare on the raw string
 * (exactly the way WeeklyDigest does) — no Date, no timezone, no locale. Self-contained:
 * does NOT depend on WeeklyDigest.
 */

/**
 * The metrics a range report can summarise. WORKOUTS and STRESS (#457) lead the list so
 * they rank first in the report; the rest keep their established order.
 */
enum class ReportMetric {
    WORKOUTS,      // logged workouts per day, count
    STRESS,        // daily stress score, 0–3 (lower is calmer)
    RECOVERY,      // Charge / recovery, 0–100
    SLEEP_HOURS,   // time asleep, hours
    HRV,           // heart-rate variability, ms
    RESTING_HR,    // resting heart rate, bpm
    STRAIN,        // Effort / strain, 0–100
    RESP_RATE,     // respiratory rate during sleep, breaths/min
    SKIN_TEMP_DEV; // skin-temperature deviation from baseline, °C (signed)

    /** Human label for the metric (matches the rest of the app's naming). */
    val label: String
        get() = when (this) {
            WORKOUTS -> "Workouts"
            STRESS -> "Stress"
            RECOVERY -> "Recovery"
            SLEEP_HOURS -> "Sleep"
            HRV -> "HRV"
            RESTING_HR -> "Resting HR"
            STRAIN -> "Strain"
            RESP_RATE -> "Respiratory rate"
            SKIN_TEMP_DEV -> "Skin temp"
        }

    /** Display unit suffix (empty for the unitless 0–100 scores and the 0–3 stress index). */
    val unit: String
        get() = when (this) {
            RECOVERY, STRAIN, STRESS -> ""
            WORKOUTS -> "/day"
            SLEEP_HOURS -> "h"
            HRV -> "ms"
            RESTING_HR -> "bpm"
            RESP_RATE -> "br/min"
            SKIN_TEMP_DEV -> "°C"
        }

    /**
     * Whether the metric's values are shown to one decimal place (fractional scores /
     * rates) rather than as whole numbers. Workouts is a whole count; stress is a 0–3
     * index shown to one decimal so small moves read.
     */
    val usesOneDecimal: Boolean
        get() = when (this) {
            SLEEP_HOURS, RESP_RATE, SKIN_TEMP_DEV, STRESS, WORKOUTS -> true
            else -> false
        }

    /**
     * True when a HIGHER value is the better outcome. Resting HR, respiratory rate and
     * stress are the metrics where lower is better. (Ignored for valence-free metrics —
     * see [framesGoodBad].)
     */
    val higherIsBetter: Boolean
        get() = when (this) {
            RESTING_HR, RESP_RATE, STRESS -> false
            else -> true
        }

    /**
     * Whether a rising/falling move carries a clear good/bad valence. False for a signed
     * deviation metric (skin-temp Δ) and for workout count (more or fewer sessions is a
     * lifestyle choice, not inherently good/bad) — the report then shows the trend
     * direction without a "good sign / worth a look" verdict and colours the change chip
     * neutrally.
     */
    val framesGoodBad: Boolean
        get() = when (this) {
            SKIN_TEMP_DEV, WORKOUTS -> false
            else -> true
        }

    /**
     * Minimum |slope-per-day| (in the metric's own units) before a trend is called
     * rising/falling rather than flat. Conservative, deterministic constants (not
     * personal baselines) so the read is stable and explainable.
     */
    val trendSlopeThreshold: Double
        get() = when (this) {
            WORKOUTS -> 0.03      // workouts / day (~0.2/week — a clear shift in habit)
            STRESS -> 0.02        // stress points / day (~0.14/week on the 0–3 scale)
            RECOVERY -> 0.5       // recovery points / day
            STRAIN -> 0.5         // Effort points / day
            SLEEP_HOURS -> 0.05   // hours / day (~3 min/day)
            HRV -> 0.4            // ms / day
            RESTING_HR -> 0.2     // bpm / day
            RESP_RATE -> 0.1      // breaths/min / day (~0.7/week flags illness onset)
            SKIN_TEMP_DEV -> 0.03 // °C / day (~0.2°C/week)
        }

    companion object {
        /** Stable iteration order, mirroring Swift's ReportMetric.allCases. */
        val allCases: List<ReportMetric> =
            listOf(
                WORKOUTS, STRESS, RECOVERY, SLEEP_HOURS, HRV, RESTING_HR, STRAIN,
                RESP_RATE, SKIN_TEMP_DEV,
            )
    }
}

/** Which way a metric moved across the range (by OLS slope vs a small threshold). */
enum class ReportTrend { RISING, FALLING, FLAT }

/** A value paired with the day it fell on ("yyyy-MM-dd"). */
data class DayValue(val day: String, val value: Double)

/**
 * One metric's summary over the report range. Only produced for metrics that carried at
 * least one value in range (so every field is meaningful — no fabricated zeros).
 */
data class MetricRangeStat(
    val metric: ReportMetric,
    /** Days carrying a value inside the range. */
    val n: Int,
    /** Mean of the in-range values. */
    val mean: Double,
    /** The lowest value and the day it fell on. */
    val min: DayValue,
    /** The highest value and the day it fell on. */
    val max: DayValue,
    /** Mean of the first half of the in-range days (by day position). */
    val firstHalfMean: Double,
    /** Mean of the second half of the in-range days (by day position). */
    val secondHalfMean: Double,
    /** Trend direction over the range (rising / falling / flat). */
    val trend: ReportTrend,
    /** The value on the latest day present in range. */
    val latest: DayValue,
) {
    /** Signed first→second half change (secondHalfMean − firstHalfMean), metric units. */
    val halfDelta: Double get() = secondHalfMean - firstHalfMean
}

/** The complete shareable trends report over a date range. */
data class RangeReport(
    /** Inclusive start day of the range ("yyyy-MM-dd"). */
    val start: String,
    /** Inclusive end day of the range ("yyyy-MM-dd"). */
    val end: String,
    /** Number of calendar days the range spans (inclusive). 0 for an invalid range. */
    val totalDays: Int,
    /**
     * Per-metric stats, in ReportMetric.allCases order, for metrics that had ≥ 1 value in
     * range. Metrics with no in-range data are OMITTED entirely.
     */
    val metrics: List<MetricRangeStat>,
    /**
     * A short headline set the UI can show at the top — one line per present metric,
     * most-notable first, already plain-English.
     */
    val headlines: List<String>,
) {
    /** Look up one metric's stat (null when that metric had no in-range data). */
    fun stat(metric: ReportMetric): MetricRangeStat? = metrics.firstOrNull { it.metric == metric }

    /** True when no metric carried a single reading in range. */
    val isEmpty: Boolean get() = metrics.isEmpty()
}

object RangeReportEngine {

    /**
     * Build a RangeReport over the inclusive [start, end] day range from each metric's
     * day→value series.
     *
     * @param metrics per-metric day→value maps ("yyyy-MM-dd" → value). Missing metrics and
     *   missing days are simply absent; this is robust to sparse data.
     * @param start inclusive range start, "yyyy-MM-dd".
     * @param end inclusive range end, "yyyy-MM-dd".
     *
     * If [end] sorts before [start] the range is treated as empty (no metrics, 0 days).
     */
    fun build(
        metrics: Map<ReportMetric, Map<String, Double>>,
        start: String,
        end: String,
    ): RangeReport {
        // A valid window requires start <= end (ISO string compare == chronological).
        if (start > end) {
            return RangeReport(start = start, end = end, totalDays = 0,
                metrics = emptyList(), headlines = emptyList())
        }
        val totalDays = dayCount(start, end)

        val stats = mutableListOf<MetricRangeStat>()
        for (metric in ReportMetric.allCases) {
            val series = metrics[metric] ?: emptyMap()
            // In-range entries, ordered chronologically by their day string.
            val ordered = series
                .filter { it.key >= start && it.key <= end }
                .toList()
                .sortedBy { it.first }
            if (ordered.isEmpty()) continue   // omit metrics with no data

            val days = ordered.map { it.first }
            val values = ordered.map { it.second }
            val n = values.size

            val mn = mean(values)

            // Min / max carry the day they fell on. On ties the EARLIEST day wins (values
            // are already chronological, so the first hit is earliest).
            var minDV = DayValue(days[0], values[0])
            var maxDV = DayValue(days[0], values[0])
            for (i in 1 until n) {
                if (values[i] < minDV.value) minDV = DayValue(days[i], values[i])
                if (values[i] > maxDV.value) maxDV = DayValue(days[i], values[i])
            }

            // Split down the middle by POSITION. Odd counts give the larger half to the
            // second half (the back of the range), so the "recent" read is never starved.
            val mid = n / 2
            val firstHalf = values.subList(0, mid)
            val secondHalf = values.subList(mid, n)
            // With n == 1 the first half is empty; fall back to the single value so both
            // halves are defined and equal (→ flat, no fabricated movement).
            val firstMean = if (firstHalf.isEmpty()) mn else mean(firstHalf)
            val secondMean = if (secondHalf.isEmpty()) mn else mean(secondHalf)

            val slope = leastSquaresSlope(values)
            val trend = trendFromSlope(slope, metric.trendSlopeThreshold)

            val latest = DayValue(days[n - 1], values[n - 1])

            stats.add(
                MetricRangeStat(
                    metric = metric, n = n, mean = mn, min = minDV, max = maxDV,
                    firstHalfMean = firstMean, secondHalfMean = secondMean,
                    trend = trend, latest = latest,
                ),
            )
        }

        val headlines = makeHeadlines(stats)
        return RangeReport(start = start, end = end, totalDays = totalDays,
            metrics = stats, headlines = headlines)
    }

    // Headlines

    /**
     * One plain-English line per present metric, ranked most-notable first. "Notable" is
     * the absolute first→second-half change scaled by the metric's trend threshold, so
     * movers on different units are comparable. Folds in good/bad framing.
     */
    internal fun makeHeadlines(stats: List<MetricRangeStat>): List<String> =
        stats.sortedByDescending { salience(it) }.map { headline(it) }

    /** |half delta| normalised by the metric's trend threshold (a units-agnostic move). */
    internal fun salience(s: MetricRangeStat): Double {
        val t = s.metric.trendSlopeThreshold
        return if (t > 0) abs(s.halfDelta) / t else abs(s.halfDelta)
    }

    /** Render one metric's headline. Trend word + good/bad framing + the two half means. */
    internal fun headline(s: MetricRangeStat): String {
        val word = when (s.trend) {
            ReportTrend.RISING -> "trending up"
            ReportTrend.FALLING -> "trending down"
            ReportTrend.FLAT -> "holding steady"
        }
        val frame = if (s.trend == ReportTrend.FLAT || !s.metric.framesGoodBad) {
            // Flat, or a signed-deviation metric with no inherent good/bad direction.
            ""
        } else {
            val up = s.trend == ReportTrend.RISING
            val good = up == s.metric.higherIsBetter
            if (good) " - a good sign" else " - worth a look"
        }
        val unit = if (s.metric.unit.isEmpty()) "" else " ${s.metric.unit}"
        return "${s.metric.label} is $word (avg ${round1(s.firstHalfMean)}$unit → " +
            "${round1(s.secondHalfMean)}$unit)$frame."
    }

    // Trend

    /**
     * Map an OLS slope-per-day to a direction against a small threshold. Within ±
     * threshold reads as flat (noise), so a near-level series never fakes a trend.
     */
    internal fun trendFromSlope(slope: Double, threshold: Double): ReportTrend = when {
        slope > threshold -> ReportTrend.RISING
        slope < -threshold -> ReportTrend.FALLING
        else -> ReportTrend.FLAT
    }

    // Day math (timezone/locale-free, ISO string in → integer out)

    /**
     * Inclusive day count between two "yyyy-MM-dd" days. 1 for the same day. 0 when either
     * day is unparseable or end sorts before start.
     */
    internal fun dayCount(start: String, end: String): Int {
        val s = parseYMD(start) ?: return 0
        val e = parseYMD(end) ?: return 0
        val diff = julianDayNumber(e.first, e.second, e.third) -
            julianDayNumber(s.first, s.second, s.third)
        return if (diff < 0) 0 else diff + 1
    }

    /** Parse "yyyy-MM-dd" into validated integer components (real calendar date only). */
    internal fun parseYMD(str: String): Triple<Int, Int, Int>? {
        val parts = str.split("-")
        if (parts.size != 3) return null
        val y = parts[0].toIntOrNull() ?: return null
        val m = parts[1].toIntOrNull() ?: return null
        val d = parts[2].toIntOrNull() ?: return null
        if (m !in 1..12) return null
        if (d < 1 || d > daysInMonth(y, m)) return null
        return Triple(y, m, d)
    }

    internal fun daysInMonth(y: Int, m: Int): Int = when (m) {
        1, 3, 5, 7, 8, 10, 12 -> 31
        4, 6, 9, 11 -> 30
        2 -> if (isLeap(y)) 29 else 28
        else -> 0
    }

    internal fun isLeap(y: Int): Boolean = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)

    /** Proleptic-Gregorian date → Julian Day Number (integer-only, timezone-free). */
    internal fun julianDayNumber(y: Int, m: Int, d: Int): Int {
        val a = (14 - m) / 12
        val yy = y + 4800 - a
        val mm = m + 12 * a - 3
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
    }

    // Stats (self-contained so the Swift mirror is line-for-line)

    internal fun mean(values: List<Double>): Double {
        if (values.isEmpty()) return 0.0
        return values.sum() / values.size
    }

    /** OLS slope of value vs the 0-based index (per-day trend); 0 for < 2 points. */
    internal fun leastSquaresSlope(values: List<Double>): Double {
        val n = values.size
        if (n < 2) return 0.0
        val meanX = (n - 1) / 2.0
        val meanY = mean(values)
        var num = 0.0
        var den = 0.0
        values.forEachIndexed { i, v ->
            val dx = i - meanX
            num += dx * (v - meanY)
            den += dx * dx
        }
        return if (den == 0.0) 0.0 else num / den
    }

    /**
     * Round to one decimal place, half-away-from-zero, matching Swift's Double.rounded()
     * so the headline strings are byte-identical across platforms.
     */
    internal fun round1(x: Double): Double {
        val scaled = x * 10.0
        val rounded = if (scaled < 0) -((-scaled) + 0.5).toLong() else (scaled + 0.5).toLong()
        return rounded / 10.0
    }
}
