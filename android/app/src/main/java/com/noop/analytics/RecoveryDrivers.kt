package com.noop.analytics

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.roundToInt

// RecoveryDrivers.kt - the USER-FACING "What shaped it" breakdown for the Charge (recovery) score.
//
// Kotlin twin of the Swift RecoveryScorer chargeDrivers reference. Where RecoveryScorerTrace emits a
// terse engineer-facing strap-log trace, this produces the ordered, plain-English driver rows the
// dashboard renders UNDER the Charge ring: one row per real term, each carrying the signed point
// contribution to the score (deltaPoints), the night's value, the personal baseline it was scored
// against, and a short verdict.
//
// HONEST BY CONSTRUCTION. Every row is recomputed from the SAME inputs RecoveryScorer.recovery reads,
// with the SAME zScore call, weights and logistic, so a driver can never describe a term the score
// did not actually use. A MISSING input yields NO row (never a fabricated zero-contribution row): the
// term simply drops, exactly as it drops + renormalizes inside recovery(...). deltaPoints is the
// term's MARGINAL effect on the final 0-100 score: score(actual) minus score(this term neutralized to
// its personal baseline, i.e. z = 0), holding the other terms. That is a real local sensitivity, not a
// linear apportionment, so the signed points are exactly "how many points this signal moved Charge
// versus sitting at your baseline". Pure + side-effect-free (no clock, no I/O), so a fixture night pins
// the exact rows. No em-dashes, no PII (values + baselines are the user's own, never logged here).

/**
 * One driver row behind the Charge (recovery) score, in the SHARED CONTRACT shape the iOS/macOS and
 * Android dashboards both render. Field names are byte-identical across platforms.
 *
 * @property label short signal name, e.g. "Resting HR".
 * @property deltaPoints signed contribution to the 0-100 Charge score versus this signal sitting at
 *   the personal baseline (positive = lifted Charge, negative = pulled it down). A real marginal
 *   sensitivity, never a fabricated apportionment.
 * @property valueText the night's value, formatted with its unit, e.g. "58 bpm".
 * @property baselineText the personal baseline the value was scored against, e.g. "61 bpm baseline".
 * @property verdict short plain-English read, e.g. "below baseline, supporting recovery".
 */
data class ChargeDriver(
    val label: String,
    val deltaPoints: Int,
    val valueText: String,
    val baselineText: String,
    val verdict: String,
)

object RecoveryDrivers {

    /**
     * The ordered "What shaped it" driver rows for one night's Charge score, or an EMPTY list when the
     * score itself can't compute (cold-start HRV baseline not usable, or a missing hard input) - the same
     * gate RecoveryScorer.recovery returns null on. Each present term gets exactly one row; a term whose
     * input is missing yields NO row.
     *
     * Mirrors RecoveryScorer.recovery / RecoveryScorerTrace argument-for-argument so the rows are scored
     * against the identical inputs as the headline number. Takes [BaselineState] so each row can name the
     * personal baseline (mean) it was measured against.
     *
     * @param hrv tonight's HRV (RMSSD, ms).
     * @param rhr tonight's resting HR (bpm).
     * @param resp tonight's respiration (rpm); null drops the resp row.
     * @param hrvBaseline HRV baseline (required; an unusable one yields an empty list, matching the
     *   recovery cold-start gate).
     * @param rhrBaseline resting-HR baseline; null drops the RHR row.
     * @param respBaseline respiration baseline; null drops the resp row.
     * @param sleepPerf rest-quality proxy in 0..1 (Rest composite / 100, or efficiency); null drops the
     *   Sleep row.
     * @param skinTempDev tonight's skin-temperature deviation from the personal baseline (raw +/- C);
     *   null drops the Skin temp row. Surfaced as a RELATIVE deviation, never an absolute temperature.
     */
    fun chargeDrivers(
        hrv: Double,
        rhr: Double,
        resp: Double?,
        hrvBaseline: BaselineState,
        rhrBaseline: BaselineState?,
        respBaseline: BaselineState?,
        sleepPerf: Double?,
        skinTempDev: Double? = null,
    ): List<ChargeDriver> {
        // Cold-start gate: no usable HRV baseline -> no score -> no drivers (honest empty, not faked rows).
        if (!hrvBaseline.usable) return emptyList()

        // Build the SAME (z, weight) term set recovery(...) builds, in the SAME append order, capturing
        // each term's identity so a single term can be neutralized to compute its marginal point swing.
        data class Term(val z: Double, val w: Double)

        val terms = ArrayList<Term>()

        // HRV term: higher is better. Always present once the baseline is usable.
        val hrvZ = RecoveryScorer.zScore(hrv, hrvBaseline.baseline, hrvBaseline.spread)
        val hrvIdx = terms.size
        terms.add(Term(hrvZ, RecoveryScorer.wHRV))

        // RHR term: lower is better -> (mu - x) / sigma.
        var rhrIdx = -1
        if (rhrBaseline != null) {
            val z = RecoveryScorer.zScore(rhrBaseline.baseline, rhr, rhrBaseline.spread)
            rhrIdx = terms.size
            terms.add(Term(z, RecoveryScorer.wRHR))
        }

        // Resp term: lower is better, needs BOTH the value and a baseline.
        var respIdx = -1
        if (resp != null && respBaseline != null) {
            val z = RecoveryScorer.zScore(respBaseline.baseline, resp, respBaseline.spread)
            respIdx = terms.size
            terms.add(Term(z, RecoveryScorer.wResp))
        }

        // Sleep-performance / Rest-quality term: no baseline, centered at sleepPerfCenter.
        var sleepIdx = -1
        if (sleepPerf != null) {
            val z = (sleepPerf - RecoveryScorer.sleepPerfCenter) / RecoveryScorer.sleepPerfScale
            sleepIdx = terms.size
            terms.add(Term(z, RecoveryScorer.wSleep))
        }

        // Skin-temp term: SYMMETRIC penalty on |deviation|, added only when supplied.
        var skinIdx = -1
        if (skinTempDev != null) {
            val z = -abs(skinTempDev) / RecoveryScorer.skinTempDevScale
            skinIdx = terms.size
            terms.add(Term(z, RecoveryScorer.wSkinTemp))
        }

        // The actual score, EXACTLY as recovery(...) computes it (so the rows can't disagree with the ring).
        val totalWeight = terms.sumOf { it.w }
        if (totalWeight <= 0.0) return emptyList()
        val actual = scoreOf(terms.sumOf { it.z * it.w } / totalWeight)

        // Marginal point swing of term [idx]: actual score minus the score with that ONE term neutralized
        // to z = 0 (the signal sitting AT its personal baseline), the other terms and weights unchanged.
        // The denominator stays the full totalWeight - the term still occupies its weight at z = 0, the
        // honest "what if this signal had been exactly average for you" counterfactual.
        fun delta(idx: Int): Int {
            val neutralZ = terms.withIndex().sumOf { (i, t) -> if (i == idx) 0.0 else t.z * t.w } / totalWeight
            return (actual - scoreOf(neutralZ)).roundToInt()
        }

        // One row per present term, appended in the SAME order the iOS twin uses (HRV, resting HR,
        // Sleep, respiration, skin temp), then sorted biggest-mover-first so the row that explains the
        // most sits on top. Labels / value text / verdicts are byte-identical to the Swift canonical.
        val drivers = ArrayList<ChargeDriver>()

        drivers.add(
            ChargeDriver(
                label = "Heart rate variability",
                deltaPoints = delta(hrvIdx),
                valueText = "${hrv.roundToInt()} ms",
                baselineText = "${hrvBaseline.baseline.roundToInt()} ms baseline",
                verdict = directionVerdict(hrvZ, good = "above baseline, supporting recovery",
                    flat = "at baseline", bad = "below baseline, limiting recovery"),
            ),
        )
        if (rhrIdx >= 0 && rhrBaseline != null) {
            // RHR z is already oriented "higher z = better" (lower RHR), so a positive z is good.
            drivers.add(
                ChargeDriver(
                    label = "Resting heart rate",
                    deltaPoints = delta(rhrIdx),
                    valueText = "${rhr.roundToInt()} bpm",
                    baselineText = "${rhrBaseline.baseline.roundToInt()} bpm baseline",
                    verdict = directionVerdict(terms[rhrIdx].z, good = "below baseline, supporting recovery",
                        flat = "at baseline", bad = "above baseline, limiting recovery"),
                ),
            )
        }
        if (sleepIdx >= 0 && sleepPerf != null) {
            drivers.add(
                ChargeDriver(
                    label = "Sleep quality",
                    deltaPoints = delta(sleepIdx),
                    valueText = "${(sleepPerf * 100.0).roundToInt()}%",
                    baselineText = "",   // centred on a fixed "good night", not a learned baseline
                    verdict = directionVerdict(terms[sleepIdx].z, good = "a strong night, supporting recovery",
                        flat = "a typical night", bad = "below a good night, limiting recovery"),
                ),
            )
        }
        if (respIdx >= 0 && resp != null && respBaseline != null) {
            drivers.add(
                ChargeDriver(
                    label = "Respiratory rate",
                    deltaPoints = delta(respIdx),
                    valueText = String.format(java.util.Locale.US, "%.1f br/min", resp),
                    baselineText = String.format(java.util.Locale.US, "%.1f br/min baseline", respBaseline.baseline),
                    verdict = directionVerdict(terms[respIdx].z, good = "below baseline, supporting recovery",
                        flat = "at baseline", bad = "above baseline, limiting recovery"),
                ),
            )
        }
        if (skinIdx >= 0 && skinTempDev != null) {
            // Skin temp is a SYMMETRIC penalty: only |deviation| matters. Surface it as a RELATIVE
            // deviation (signed +/- C from baseline), never an absolute temperature.
            drivers.add(
                ChargeDriver(
                    label = "Skin temperature",
                    deltaPoints = delta(skinIdx),
                    valueText = String.format(java.util.Locale.US, "%+.1f C vs baseline", skinTempDev),
                    baselineText = "",   // a deviation already; the reference is the personal baseline (0)
                    verdict = skinTempVerdict(skinTempDev),
                ),
            )
        }

        // Biggest mover first; a stable sort preserves the iOS append order on ties.
        return drivers.sortedByDescending { abs(it.deltaPoints) }
    }

    /** The Charge logistic, IDENTICAL to RecoveryScorer.recovery's final squash. */
    private fun scoreOf(z: Double): Double {
        val s = 100.0 / (1.0 + exp(-RecoveryScorer.logisticK * (z - RecoveryScorer.logisticZ0)))
        return s.coerceIn(0.0, 100.0)
    }

    /**
     * Direction verdict matching the Swift canonical: an "already oriented so higher z is better"
     * z reads as supporting recovery when positive (the signal is on the good side of baseline),
     * limiting recovery when negative, and right at baseline when exactly zero. Byte-for-byte the
     * same strings RecoveryScorer's Swift verdicts produce, so the iOS and Android rows match.
     */
    private fun directionVerdict(z: Double, good: String, flat: String, bad: String): String = when {
        z > 0.0 -> good
        z < 0.0 -> bad
        else -> flat
    }

    /** Half-width (C) of the "typical" skin-temp band; matches Swift skinTempTypicalBandC. */
    private const val SKIN_TEMP_TYPICAL_BAND_C: Double = 0.3

    /**
     * Skin-temp verdict (symmetric): a drift within the typical band reads neutral, beyond it limits
     * recovery, warmer or cooler. Mirrors the Swift skinTempVerdict exactly.
     */
    private fun skinTempVerdict(dev: Double): String = when {
        abs(dev) <= SKIN_TEMP_TYPICAL_BAND_C -> "near baseline"
        dev > 0.0 -> "warmer than baseline, limiting recovery"
        else -> "cooler than baseline, limiting recovery"
    }
}
