package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample

// SleepReadout.kt - Kotlin twin of SleepReadout.swift. Pure values for the Sleep live-readout
// panel. No state, no IO, no em-dashes.

object SleepReadout {
    /** HR samples per minute over the stream's own span. 0 when fewer than 2 samples. */
    fun hrDensityPerMinute(hr: List<HrSample>): Double {
        if (hr.size < 2) return 0.0
        val sorted = hr.sortedBy { it.ts }
        val spanS = (sorted.last().ts - sorted.first().ts).toDouble()
        if (spanS <= 0) return 0.0
        return sorted.size / (spanS / 60.0)
    }

    /** Fraction of the HR window the gravity stream spans, in [0, 1]. Below SleepStager's
     *  sparseGravitySpanFrac means tonight's gravity is sparse. */
    fun gravityCoverageFraction(gravity: List<GravitySample>, hr: List<HrSample>): Double {
        if (gravity.size < 2 || hr.size < 2) return 0.0
        val g = gravity.sortedBy { it.ts }
        val h = hr.sortedBy { it.ts }
        val hrSpan = (h.last().ts - h.first().ts).toDouble()
        if (hrSpan <= 0) return 0.0
        val gravSpan = (g.last().ts - g.first().ts).toDouble()
        return maxOf(0.0, minOf(1.0, gravSpan / hrSpan))
    }

    /** The gate named by the most recent gate-trace line in the tagged log tail, or null. */
    fun lastGateFired(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val idx = line.indexOf("gate=")
            if (idx < 0) continue
            val after = line.substring(idx + "gate=".length)
            val token = after.takeWhile { it != ' ' }
            if (token.isNotEmpty()) return token
        }
        return null
    }
}

/**
 * Pure values for the Recovery (Charge) and HRV live-readout panels (Test Centre Group G). Kotlin twin of
 * the Swift TestReadout. Each parses the tagged log tail the Recovery / HRV emitters write, so the panel
 * reflects exactly the last Charge breakdown or HRV computation. No state, no IO, no em-dashes.
 */
object TestReadout {

    /**
     * The most recent Charge score + band fragment from the RECOVERY-tagged tail, or null. The emitter
     * writes "[recovery] charge day=... score=<n> band=<b> ..." (or a "nilScore reason=..." line when the
     * night could not be scored). Returns the score/band fragment so the panel reads the same number the
     * dashboard shows; falls back to the nil-reason when there is no score yet. Mirrors the Swift parser.
     */
    fun lastChargeBreakdown(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val si = line.indexOf("score=")
            if (si >= 0) {
                val rest = line.substring(si)            // "score=.. band=.. (..)"
                val upto = rest.takeWhile { it != '(' }.trim()
                if (upto.isNotEmpty()) return upto
            }
            val ni = line.indexOf("nilScore reason=")
            if (ni >= 0) {
                val token = line.substring(ni + "nilScore reason=".length).takeWhile { it != ' ' }
                if (token.isNotEmpty()) return "no score ($token)"
            }
        }
        return null
    }

    /**
     * The most recent HRV result fragment from the HRV-tagged tail, or null. The emitter writes
     * "[hrv] hrv rmssd=<n>ms sdnn=<n>ms meanNN=<n>ms" on success, or "[hrv] hrv result=nil (..)" when a
     * gate refused the reading. Returns the rmssd/sdnn fragment, or the nil note, so the panel reads the
     * same outcome the snapshot screen showed. Mirrors the Swift parser.
     */
    fun lastHrvComputation(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val ri = line.indexOf("rmssd=")
            if (ri >= 0) {
                val frag = line.substring(ri).trim()
                if (frag.isNotEmpty()) return frag
            }
            if (line.contains("result=nil")) return "no reading (filtered out)"
        }
        return null
    }
}
