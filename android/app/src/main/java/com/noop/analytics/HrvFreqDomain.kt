package com.noop.analytics

import com.noop.data.RrInterval
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * HrvFreqDomain.kt, frequency-domain HRV (LF / HF / LF-HF / total power) over an R-R series.
 *
 * Byte-for-byte twin of StrandAnalytics/HRVFreqDomain.swift. PURELY ADDITIVE: no change to any
 * Charge / Effort / Rest / sleep output; the time-domain HrvAnalyzer (RMSSD / SDNN / pNN50) is untouched.
 *
 * WHY LOMB-SCARGLE, NOT AN FFT. A tachogram (successive R-R intervals against their own cumulative time)
 * is UNEVENLY sampled by construction. Resampling onto a uniform grid for an FFT is a low-pass
 * interpolation that distorts the HF (respiratory) band. The Lomb-Scargle periodogram (Lomb 1976,
 * Scargle 1982) estimates the spectrum DIRECTLY from the irregular samples with no interpolation, and is the
 * estimator recommended for HRV on irregular tachograms (Laguna/Moody/Mark 1998; Clifford/Tarassenko 2005).
 * This generalises the band-limited DFT in SleepStagerV2.respRegularity (a uniform-grid DFT over the resp
 * band): same "probe only the frequencies we care about" idea, with the Lomb-Scargle estimator so no
 * resampling is needed.
 *
 * TASK FORCE (1996) bands: LF 0.04–0.15 Hz, HF 0.15–0.40 Hz, LF/HF the ratio, total power VLF+LF+HF.
 * SPAN GATES: HF needs >= 60 s of R-R span; LF (and LF/HF, total power) need >= 250 s. Below 60 s → null;
 * 60..250 s → HF only (LF/LFHF null). Powers in ms^2. APPROXIMATE, non-clinical.
 */
object HrvFreqDomain {

    // ── Band edges (Hz) and span gates (s), mirror the Swift twin ──
    const val VLF_LOW_HZ: Double = 0.0033
    const val LF_LOW_HZ: Double = 0.04
    const val LF_HIGH_HZ: Double = 0.15
    const val HF_LOW_HZ: Double = 0.15
    const val HF_HIGH_HZ: Double = 0.40

    const val MIN_SPAN_FOR_HF_SEC: Double = 60.0
    const val MIN_SPAN_FOR_LF_SEC: Double = 250.0

    const val MIN_BEATS: Int = 20
    const val FREQ_STEP_HZ: Double = 0.005

    /**
     * Frequency-domain HRV over a window. [lf] / [lfhf] are null when span < 250 s (60..250 s gives HF
     * only). [hf] and [totalPower] are present whenever the result is non-null (span >= 60 s). ms^2.
     */
    data class Bands(
        val lf: Double?,
        val hf: Double,
        val lfhf: Double?,
        val totalPower: Double,
    )

    /**
     * Frequency-domain HRV from R-R intervals (each with a ts in seconds and rrMs). Cleaned with the SAME
     * range + Malik ectopic pipeline ([HrvAnalyzer.cleanRR]) before the tachogram is built. null when too
     * few clean beats or span < [MIN_SPAN_FOR_HF_SEC].
     */
    fun freqDomain(rr: List<RrInterval>): Bands? {
        val raw = rr.sortedBy { it.ts }.map { it.rrMs.toDouble() }
        return freqDomainRaw(raw)
    }

    /** As [freqDomain] but from a raw, time-ordered R-R series in milliseconds. */
    fun freqDomainRaw(rawRR: List<Double>): Bands? {
        val clean = HrvAnalyzer.cleanRR(rawRR)
        if (clean.size < MIN_BEATS) return null

        // Tachogram: time of beat k = cumulative sum of the first k clean intervals (seconds); sample = R-R.
        val times = DoubleArray(clean.size)
        var acc = 0.0
        for (i in clean.indices) {
            times[i] = acc / 1000.0
            acc += clean[i]
        }
        val span = times[times.size - 1] - times[0]
        if (span < MIN_SPAN_FOR_HF_SEC) return null

        val mean = clean.sum() / clean.size.toDouble()
        val y = DoubleArray(clean.size) { clean[it] - mean }

        val hf = bandPower(times, y, HF_LOW_HZ, HF_HIGH_HZ)

        val lfTrusted = span >= MIN_SPAN_FOR_LF_SEC
        val lf: Double? = if (lfTrusted) bandPower(times, y, LF_LOW_HZ, LF_HIGH_HZ) else null

        val lfhf: Double? = if (lf != null && hf > 0) lf / hf else null

        // Total power = the SUM of the sub-band integrals (VLF + LF + HF) when LF is trusted, otherwise just
        // HF. Summing the bands (not one wide [VLF..HF] integral) guarantees totalPower >= hf and stays
        // grid-consistent with the reported bands: a single wide integral samples on a grid offset from the
        // HF-only grid, so for a narrow peak it can undercount the HF region and fall below hf. Mirrors Swift.
        val totalPower = if (lfTrusted && lf != null) {
            bandPower(times, y, VLF_LOW_HZ, LF_LOW_HZ) + lf + hf
        } else {
            hf
        }

        return Bands(lf = lf, hf = hf, lfhf = lfhf, totalPower = totalPower)
    }

    // ── Lomb-Scargle band integral ──

    /**
     * Trapezoidal integral of the Lomb-Scargle power across [fLow, fHigh], sampled every [FREQ_STEP_HZ].
     * Press et al. (Numerical Recipes) normalisation, integrated over frequency to a band POWER (ms^2).
     */
    internal fun bandPower(times: DoubleArray, y: DoubleArray, fLow: Double, fHigh: Double): Double {
        if (fHigh <= fLow) return 0.0
        val n = y.size.toDouble()
        var variance = 0.0
        for (v in y) variance += v * v
        variance /= n
        if (variance <= 0) return 0.0

        var power = 0.0
        var prevP = 0.0
        var prevF = fLow
        var first = true
        var f = fLow
        while (f <= fHigh + 1e-12) {
            val p = lombScarglePower(times, y, f, variance)
            if (!first) {
                power += 0.5 * (p + prevP) * (f - prevF)
            }
            prevP = p
            prevF = f
            first = false
            f += FREQ_STEP_HZ
        }
        return power
    }

    /**
     * Lomb-Scargle normalised power at a single frequency (Press et al. form). [variance] is the sample
     * variance of the mean-removed series. The time-offset tau makes the estimate invariant to time
     * translation, which is what correctly handles the uneven tachogram spacing.
     */
    internal fun lombScarglePower(times: DoubleArray, y: DoubleArray, freqHz: Double, variance: Double): Double {
        val omega = 2.0 * PI * freqHz

        var sin2 = 0.0
        var cos2 = 0.0
        for (t in times) {
            val a = 2.0 * omega * t
            sin2 += sin(a)
            cos2 += cos(a)
        }
        val tau = atan2(sin2, cos2) / (2.0 * omega)

        var cTerm = 0.0
        var cDen = 0.0
        var sTerm = 0.0
        var sDen = 0.0
        for (i in times.indices) {
            val arg = omega * (times[i] - tau)
            val c = cos(arg)
            val s = sin(arg)
            cTerm += y[i] * c
            cDen += c * c
            sTerm += y[i] * s
            sDen += s * s
        }
        val cosPart = if (cDen > 0) (cTerm * cTerm) / cDen else 0.0
        val sinPart = if (sDen > 0) (sTerm * sTerm) / sDen else 0.0
        return (cosPart + sinPart) / (2.0 * variance)
    }
}
