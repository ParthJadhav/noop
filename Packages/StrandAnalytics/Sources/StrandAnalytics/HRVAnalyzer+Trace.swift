import Foundation

// HRVAnalyzer+Trace.swift - the HRV & Autonomic test-mode cleaning trace.
//
// Recomputes the cleaning-pipeline counts (range filter, Malik ectopic rejection, the minBeats gate,
// the spot rejected-fraction gate) from the SAME raw RR the analyzer reads, then reuses analyze(...)
// verbatim for the result so the trace can never disagree with the RMSSD/SDNN the screen shows. Pure
// and side-effect-free: no clock, no I/O, so a fixture beat series pins the exact lines. The HRV test
// mode gates this behind TestCentre.active(.hrv) at the call site (the spot reading); when the mode is
// off it is never called, so there is zero cost. No em-dashes. Counts and ms only, no PII.

extension HRVAnalyzer {

    /// Side-effect-free diagnostic twin of `analyze(rawRR:maxRejectedFraction:)`: returns the SAME
    /// HRVResult analyze(...) would, plus the cleaning trace. Reports nInput / nClean / rejected fraction,
    /// RMSSD / SDNN / meanNN, whether the `minBeats` gate cleared, the range + Malik ectopic rejection
    /// counts, and (when a ceiling is supplied) the spot rejected-fraction honesty gate. `path` tags the
    /// reading "spot" or "continuous" so a report shows which window produced it.
    ///
    /// The returned result IS `analyze(...)` verbatim, and every count is recomputed with the EXACT same
    /// filters (`rangeFilter` then `rejectEctopic`), so the trace and the headline can never diverge. The
    /// Kotlin twin is HrvAnalyzer.analyzeTrace.
    ///
    /// - Parameter maxRejectedFraction: the SPOT-ONLY ceiling (#585). nil (the nightly/continuous default)
    ///   skips the rejected-fraction gate, exactly like `analyze(...)`.
    /// - Parameter path: "spot" for a live snapshot, "continuous" for the nightly windowed path.
    public static func analyzeTrace(rawRR: [Double],
                                    maxRejectedFraction: Double? = nil,
                                    path: String = "spot")
        -> (result: HRVResult, trace: [String]) {

        func r2(_ x: Double) -> Double { (x * 100.0).rounded() / 100.0 }

        // The result the screen reads, verbatim, so the trace cannot diverge from it.
        let result = analyze(rawRR: rawRR, maxRejectedFraction: maxRejectedFraction)

        var lines: [String] = []
        let nInput = rawRR.count

        // Stage counts: range filter then Malik ectopic rejection (the SAME order cleanRR runs).
        let ranged = rangeFilter(rawRR)
        let clean = rejectEctopic(ranged)
        let outOfRange = nInput - ranged.count
        let ectopic = ranged.count - clean.count
        let rejectedFraction = nInput > 0 ? 1.0 - Double(clean.count) / Double(nInput) : 0.0

        lines.append("hrv path=\(path) nInput=\(nInput) nClean=\(clean.count) "
            + "rejectedFraction=\(r2(rejectedFraction))")
        lines.append("hrv reject range=\(outOfRange) (bounds \(Int(rrMinMs))..\(Int(rrMaxMs))ms) "
            + "ectopic=\(ectopic) (Malik >\(Int(ectopicThreshold * 100))% of local median)")

        // minBeats gate: the first reason analyze(...) returns an empty result.
        let minBeatsCleared = clean.count >= minBeats
        lines.append("hrv minBeats need=\(minBeats) clean=\(clean.count) "
            + "\(minBeatsCleared ? "CLEARED" : "FAILED")")

        // Spot honesty gate (#585): only when a ceiling is supplied AND minBeats cleared.
        if let ceiling = maxRejectedFraction, minBeatsCleared {
            let gatePass = !(rejectedFraction > ceiling)
            lines.append("hrv spotGate maxRejectedFraction=\(r2(ceiling)) "
                + "rejectedFraction=\(r2(rejectedFraction)) \(gatePass ? "PASS" : "FAIL")")
        }

        // RMSSD / SDNN / meanNN read from the verbatim result (nil when a gate refused the reading).
        if let rmssd = result.rmssd, let sdnn = result.sdnn, let mean = result.meanNN {
            lines.append("hrv rmssd=\(r2(rmssd))ms sdnn=\(r2(sdnn))ms meanNN=\(r2(mean))ms")
        } else {
            lines.append("hrv result=nil (a gate above refused the reading)")
        }

        return (result, lines)
    }
}
