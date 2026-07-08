import Foundation

// RecoveryScorer+Trace.swift - the Charge TERM-BREAKDOWN diagnostic (Recovery test mode).
//
// Recomputes the four-plus-one weighted Charge terms from the SAME inputs RecoveryScorer.recovery
// reads, then reuses recovery(...) verbatim for the final score so the trace can never disagree with
// the number the dashboard shows. Pure and side-effect-free: no clock, no I/O, so a fixture night
// pins the exact lines. The Recovery test mode gates this behind TestCentre.active(.recovery) at the
// call site (IntelligenceEngine recomputeRecovery); when the mode is off it is never called, so there
// is zero cost. No em-dashes. Counts, z-scores and weights only, no PII.

extension RecoveryScorer {

    /// Side-effect-free diagnostic twin of `recovery(...)`: returns the SAME score recovery(...) would,
    /// plus the per-term Charge breakdown trace. The four inputs (hrv / rhr / resp / sleepPerf) plus the
    /// skin-temp deviation each get a baseline line (mean / spread / nValid / status), a term line
    /// (z * weight), the renormalization (total weight, composite z), and the final logistic score + band.
    /// Crucially the trace names WHICH TERM WAS NIL and forced the renorm (or the nil score), so a
    /// "Charge looks wrong" report shows exactly which driver moved or was missing.
    ///
    /// Every number is computed with the EXACT same expressions as `recovery(...)` (the same zScore call,
    /// the same skin-temp penalty, the same weights), and the returned score IS `recovery(...)` verbatim,
    /// so the trace and the headline can never diverge. The Kotlin twin is RecoveryScorer.recoveryTrace.
    ///
    /// - Parameters mirror `recovery(...)` exactly, taking BaselineState so the trace can read each
    ///   driver's nValid / status; the `usable` cold-start gate is enforced through `recovery(...)`.
    public static func recoveryTrace(hrv: Double,
                                     rhr: Double,
                                     resp: Double?,
                                     hrvBaseline: BaselineState,
                                     rhrBaseline: BaselineState?,
                                     respBaseline: BaselineState?,
                                     sleepPerf: Double?,
                                     skinTempDev: Double? = nil)
        -> (score: Double?, trace: [String]) {

        func r2(_ x: Double) -> Double { (x * 100.0).rounded() / 100.0 }

        var lines: [String] = []
        var nilTerms: [String] = []

        // The score the dashboard reads, verbatim, so the trace cannot diverge from it.
        let score = recovery(hrv: hrv, rhr: rhr, resp: resp,
                             hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                             respBaseline: respBaseline, sleepPerf: sleepPerf,
                             skinTempDev: skinTempDev)

        // Cold-start gate: HRV baseline not usable -> recovery() returns nil before any term is built.
        // Report the gate so a nil Charge is explainable, then stop (no terms were scored).
        guard hrvBaseline.usable else {
            lines.append("charge nilScore reason=hrvBaselineNotUsable "
                + "hrvStatus=\(hrvBaseline.status.rawValue) hrvNValid=\(hrvBaseline.nValid) "
                + "(need nValid>=\(Baselines.minNightsSeed))")
            return (score, lines)
        }

        // Per-driver baseline state lines (mean / spread / nValid / status). The skin-temp term carries no
        // baseline arg here (skinTempDev is already a deviation), so it has no baseline line.
        lines.append("charge baseline hrv mean=\(r2(hrvBaseline.baseline)) spread=\(r2(hrvBaseline.spread)) "
            + "nValid=\(hrvBaseline.nValid) status=\(hrvBaseline.status.rawValue)")
        if let b = rhrBaseline {
            lines.append("charge baseline rhr mean=\(r2(b.baseline)) spread=\(r2(b.spread)) "
                + "nValid=\(b.nValid) status=\(b.status.rawValue)")
        }
        if let b = respBaseline {
            lines.append("charge baseline resp mean=\(r2(b.baseline)) spread=\(r2(b.spread)) "
                + "nValid=\(b.nValid) status=\(b.status.rawValue)")
        }

        // Per-term z * weight, built with the EXACT expressions recovery(...) uses. Collect the (z, w)
        // pairs in the SAME order recovery(...) appends them so the renormalization below matches.
        var terms: [(name: String, z: Double, w: Double)] = []

        // HRV term: higher is better. (Always present once usable; the cold-start guard above returned.)
        // L9: every WEIGHT / SCALE / centre constant goes through r2() too (not just the z-scores), so a
        // future non-round weight (e.g. 0.333) renders identically on Swift and Kotlin and the parity
        // fixture cannot silently desync. The values render the same as before today.
        let hrvZ = zScore(hrv, mean: hrvBaseline.baseline, spread: hrvBaseline.spread)
        terms.append(("hrv", hrvZ, wHRV))
        lines.append("charge term hrv z=\(r2(hrvZ)) w=\(r2(wHRV)) (higher HRV is better)")

        // RHR term: lower is better -> (mu - x) / sigma.
        if let b = rhrBaseline {
            let z = zScore(b.baseline, mean: rhr, spread: b.spread)
            terms.append(("rhr", z, wRHR))
            lines.append("charge term rhr z=\(r2(z)) w=\(r2(wRHR)) (lower RHR is better)")
        } else {
            nilTerms.append("rhr")
        }

        // Resp term: lower is better, optional (needs BOTH the value and a baseline).
        if let r = resp, let b = respBaseline {
            let z = zScore(b.baseline, mean: r, spread: b.spread)
            terms.append(("resp", z, wResp))
            lines.append("charge term resp z=\(r2(z)) w=\(r2(wResp)) (lower resp is better)")
        } else {
            nilTerms.append("resp")
        }

        // Sleep-performance / Rest-quality term: no baseline needed, centered at sleepPerfCenter.
        if let sp = sleepPerf {
            let z = (sp - sleepPerfCenter) / sleepPerfScale
            terms.append(("sleepPerf", z, wSleep))
            lines.append("charge term sleepPerf z=\(r2(z)) w=\(r2(wSleep)) "
                + "(rest=\(r2(sp)) center=\(r2(sleepPerfCenter)))")
        } else {
            nilTerms.append("sleepPerf")
        }

        // Skin-temp term: SYMMETRIC penalty on |deviation|, added only when supplied.
        if let dev = skinTempDev {
            let z = -abs(dev) / skinTempScaleC
            terms.append(("skinTempDev", z, wSkinTemp))
            lines.append("charge term skinTempDev z=\(r2(z)) w=\(r2(wSkinTemp)) "
                + "(dev=\(r2(dev))C penalty=-|dev|/\(r2(skinTempScaleC)))")
        } else {
            nilTerms.append("skinTempDev")
        }

        // The nil terms that dropped out and forced the weight renormalization (the killer line).
        lines.append("charge nilTerm dropped=[\(nilTerms.joined(separator: ","))] "
            + "(each dropped term renormalizes the remaining weights)")

        // Renormalization: total surviving weight and the weighted composite z, the SAME math
        // recovery(...) runs to produce the logistic input.
        let totalWeight = terms.reduce(0) { $0 + $1.w }
        let compositeZ = totalWeight > 0
            ? terms.reduce(0) { $0 + $1.z * $1.w } / totalWeight
            : 0.0
        lines.append("charge renorm totalWeight=\(r2(totalWeight)) compositeZ=\(r2(compositeZ)) "
            + "(z = sum(z*w)/sum(w))")

        // Final logistic score + band, read from recovery(...) verbatim.
        if let s = score {
            lines.append("charge score=\(r2(s)) band=\(band(s)) "
                + "(logistic k=\(r2(logisticK)) z0=\(r2(logisticZ0)))")
        } else {
            lines.append("charge nilScore reason=noValidTerms (no driver produced a usable term)")
        }

        return (score, lines)
    }
}
