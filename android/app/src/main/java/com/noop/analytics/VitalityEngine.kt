package com.noop.analytics

import kotlin.math.abs

// VitalityEngine.kt — 0–100 "Vitality" wellness score + optional "Body Age in years".
// Byte-for-byte mirror of Strand/Packages/StrandAnalytics/Sources/StrandAnalytics/VitalityEngine.swift.
//
// INDEPENDENT implementation of the published method WHOOP's "Healthspan / WHOOP Age" also uses (NOT
// medical advice; a wellness comparison, never a clinical biological age): map each wearable input to its
// published all-cause-mortality hazard ratio vs a population reference, sum the log-hazards with an
// overlap correction (correlated inputs), and convert to a "years of aging" offset via the Gompertz
// mortality-rate doubling time (~8 years per doubling). Body Age = chronological age + Δage; average =
// own age, healthier = younger. Presented with a ±band and a hard "wellness, not a clinical age" rule.
object VitalityEngine {

    private const val lnHazardPerYear = 0.6931471805599453 / 8.0   // ln(2)/8 ≈ 0.0866
    private const val overlapShrink = 0.75
    const val minBodyAge = 20.0
    const val maxBodyAge = 90.0
    private const val vitalityPerYear = 2.5
    const val minFactors = 3
    const val bandYears = 5.0

    data class Inputs(
        val chronoAge: Double,
        val restingHR: Double? = null,
        val vo2max: Double? = null,
        val expectedVO2max: Double? = null,
        val sleepHours: Double? = null,
        val sleepConsistency: Double? = null,
        val rmssd: Double? = null,
        val rmssdNorm: Double? = null,
        val steps: Double? = null,
    )

    data class Contribution(val key: String, val label: String, val lnHazard: Double)

    data class Result(
        val vitality: Double,
        val bodyAge: Double,
        val chronoAge: Double,
        val deltaYears: Double,
        val bandYears: Double,
        val contributions: List<Contribution>,
        val factorsUsed: Int,
    )

    /** Nocturnal RMSSD ~50th-pct by age (ms), piecewise-linear between decade anchors (WHOOP-window
     *  norms). The reference for the HRV factor — a person at the age norm contributes 0. */
    fun rmssdNorm(forAge: Double): Double {
        val anchors = listOf(20.0 to 47.0, 30.0 to 40.0, 40.0 to 33.0, 50.0 to 29.0, 60.0 to 25.0, 70.0 to 22.0, 80.0 to 20.0)
        if (forAge <= anchors.first().first) return anchors.first().second
        if (forAge >= anchors.last().first) return anchors.last().second
        for (i in 1 until anchors.size) {
            if (forAge <= anchors[i].first) {
                val (a0, v0) = anchors[i - 1]; val (a1, v1) = anchors[i]
                return v0 + (v1 - v0) * (forAge - a0) / (a1 - a0)
            }
        }
        return anchors.last().second
    }

    /** Sleep regularity (0–1) from nightly sleep durations (hours): 1 − coefficient of variation,
     *  clamped. < 3 nights → null. */
    fun sleepConsistency(nightlyHours: List<Double>): Double? {
        val xs = nightlyHours.filter { it > 0 }
        if (xs.size < 3) return null
        val mean = xs.sum() / xs.size
        if (mean <= 0) return null
        val variance = xs.sumOf { (it - mean) * (it - mean) } / xs.size
        val cv = kotlin.math.sqrt(variance) / mean
        return (1 - cv).coerceIn(0.0, 1.0)
    }

    /** Per-factor signed log-hazard vs the population reference (positive ages you, negative protective).
     *  Conservative published per-unit hazard ratios — see the Swift file for citations. */
    fun contributions(inputs: Inputs): List<Contribution> {
        val out = ArrayList<Contribution>()
        inputs.restingHR?.let {
            out.add(Contribution("rhr", "Resting heart rate", ((it - 65) / 10) * 0.100))
        }
        val vo2 = inputs.vo2max; val exp = inputs.expectedVO2max
        if (vo2 != null && exp != null && exp > 0) {
            out.add(Contribution("vo2max", "Cardio fitness", ((exp - vo2) / 3.5).coerceIn(-4.0, 4.0) * 0.130))
        }
        inputs.sleepHours?.let {
            val dev = maxOf(0.0, abs(it - 7.5) - 0.5)
            out.add(Contribution("sleep", "Sleep duration", dev.coerceIn(0.0, 3.0) * 0.110))
        }
        inputs.sleepConsistency?.let {
            out.add(Contribution("consistency", "Sleep regularity", (0.75 - it.coerceIn(0.0, 1.0)) * 0.450))
        }
        val h = inputs.rmssd; val norm = inputs.rmssdNorm
        if (h != null && norm != null && norm > 0) {
            out.add(Contribution("hrv", "Heart-rate variability", ((norm - h) / norm).coerceIn(-1.0, 1.0) * 0.160))
        }
        inputs.steps?.let {
            val deficit = (7000 - it.coerceIn(0.0, 11000.0)) / 1000
            out.add(Contribution("steps", "Daily steps", deficit.coerceIn(-4.0, 4.0) * 0.064))
        }
        return out
    }

    /** Full Vitality + Body Age. Returns null until at least [minFactors] inputs are present. */
    fun compute(inputs: Inputs): Result? {
        if (inputs.chronoAge <= 0) return null
        val contribs = contributions(inputs)
        if (contribs.size < minFactors) return null
        val sumLn = contribs.sumOf { it.lnHazard } * overlapShrink
        val deltaAge = sumLn / lnHazardPerYear
        val bodyAge = (inputs.chronoAge + deltaAge).coerceIn(minBodyAge, maxBodyAge)
        val delta = inputs.chronoAge - bodyAge
        val vitality = (50 + delta * vitalityPerYear).coerceIn(0.0, 100.0)
        return Result(vitality, bodyAge, inputs.chronoAge, delta, bandYears, contribs, contribs.size)
    }
}
