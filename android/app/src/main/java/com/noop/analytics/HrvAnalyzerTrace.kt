package com.noop.analytics

// HrvAnalyzerTrace.kt - Kotlin twin of HRVAnalyzer+Trace.swift. The HRV & Autonomic test-mode cleaning
// trace.
//
// Recomputes the cleaning-pipeline counts (range filter, Malik ectopic rejection, the minBeats gate, the
// spot rejected-fraction gate) from the SAME raw RR the analyzer reads, then reuses analyzeRaw(...)
// verbatim for the result so the trace can never disagree with the RMSSD/SDNN the screen shows. Pure and
// side-effect-free: no clock, no I/O, so a fixture beat series pins the exact lines. The HRV test mode
// gates this behind TestCentre.active(HRV) at the call site (the spot reading); when the mode is off it
// is never called, so there is zero cost. Byte-aligned with the Swift line shape. No em-dashes.

object HrvAnalyzerTrace {

    private fun r2(x: Double): Double = Math.round(x * 100.0) / 100.0

    /**
     * Side-effect-free diagnostic twin of [HrvAnalyzer.analyzeRaw]: returns the SAME HrvResult
     * analyzeRaw(...) would, plus the cleaning trace. Reports nInput / nClean / rejected fraction,
     * RMSSD / SDNN / meanNN, whether the [HrvAnalyzer.MIN_BEATS] gate cleared, the range + Malik ectopic
     * rejection counts, and (when a ceiling is supplied) the spot rejected-fraction honesty gate. [path]
     * tags the reading "spot" or "continuous" so a report shows which window produced it.
     *
     * The returned result IS analyzeRaw(...) verbatim, and every count is recomputed with the EXACT same
     * filters (rangeFilter then rejectEctopic), so the trace and the headline can never diverge. Mirrors
     * the Swift HRVAnalyzer.analyzeTrace.
     *
     * @param maxRejectedFraction the SPOT-ONLY ceiling (#585). null (the nightly/continuous default)
     *   skips the rejected-fraction gate, exactly like analyzeRaw(...).
     * @param path "spot" for a live snapshot, "continuous" for the nightly windowed path.
     */
    fun analyzeTrace(
        rawRR: List<Double>,
        maxRejectedFraction: Double? = null,
        path: String = "spot",
    ): Pair<HrvAnalyzer.HrvResult, List<String>> {
        // The result the screen reads, verbatim, so the trace cannot diverge from it.
        val result = HrvAnalyzer.analyzeRaw(rawRR, maxRejectedFraction)

        val lines = ArrayList<String>()
        val nInput = rawRR.size

        // Stage counts: range filter then Malik ectopic rejection (the SAME order cleanRR runs).
        val ranged = HrvAnalyzer.rangeFilter(rawRR)
        val clean = HrvAnalyzer.rejectEctopic(ranged)
        val outOfRange = nInput - ranged.size
        val ectopic = ranged.size - clean.size
        val rejectedFraction = if (nInput > 0) 1.0 - clean.size.toDouble() / nInput.toDouble() else 0.0

        lines.add(
            "hrv path=$path nInput=$nInput nClean=${clean.size} " +
                "rejectedFraction=${r2(rejectedFraction)}",
        )
        lines.add(
            "hrv reject range=$outOfRange " +
                "(bounds ${HrvAnalyzer.RR_MIN_MS.toInt()}..${HrvAnalyzer.RR_MAX_MS.toInt()}ms) " +
                "ectopic=$ectopic (Malik >${(HrvAnalyzer.ECTOPIC_THRESHOLD * 100).toInt()}% of local median)",
        )

        // minBeats gate: the first reason analyzeRaw(...) returns an empty result.
        val minBeatsCleared = clean.size >= HrvAnalyzer.MIN_BEATS
        lines.add(
            "hrv minBeats need=${HrvAnalyzer.MIN_BEATS} clean=${clean.size} " +
                if (minBeatsCleared) "CLEARED" else "FAILED",
        )

        // Spot honesty gate (#585): only when a ceiling is supplied AND minBeats cleared.
        if (maxRejectedFraction != null && minBeatsCleared) {
            val gatePass = !(rejectedFraction > maxRejectedFraction)
            lines.add(
                "hrv spotGate maxRejectedFraction=${r2(maxRejectedFraction)} " +
                    "rejectedFraction=${r2(rejectedFraction)} ${if (gatePass) "PASS" else "FAIL"}",
            )
        }

        // RMSSD / SDNN / meanNN read from the verbatim result (null when a gate refused the reading).
        val rmssd = result.rmssd
        val sdnn = result.sdnn
        val mean = result.meanNN
        if (rmssd != null && sdnn != null && mean != null) {
            lines.add("hrv rmssd=${r2(rmssd)}ms sdnn=${r2(sdnn)}ms meanNN=${r2(mean)}ms")
        } else {
            lines.add("hrv result=nil (a gate above refused the reading)")
        }

        return result to lines
    }
}
