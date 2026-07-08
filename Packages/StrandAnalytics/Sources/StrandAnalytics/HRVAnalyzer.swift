import Foundation
import WhoopProtocol

// HRVAnalyzer.swift — RMSSD + SDNN from RR intervals with cleaning.
//
// Ported from server/ingest/app/analysis/hrv.py. The Task Force (1996) RMSSD and
// SDNN definitions are reproduced exactly:
//
//   RMSSD = sqrt( mean( (NN[i+1] − NN[i])^2 ) )           (Task Force 1996)
//   SDNN  = sample standard deviation of NN (ddof = 1)     (Task Force 1996)
//
// Cleaning pipeline:
//   1. Range filter: drop intervals outside [RR_MIN_MS, RR_MAX_MS] = [300, 2000] ms.
//   2. Ectopic rejection: drop beats whose RR deviates > ~20% from a local median
//      (Malik-style filter).
//   3. Require >= MIN_BEATS (20) valid intervals before a trustworthy result.
//
// NOTE: the Python source runs neurokit2's Kubios / Lipponen–Tarvainen (2019)
// artifact classifier, which is unavailable on-device. We substitute the
// classical Malik 20% local-median rule (Malik et al. 1989), the most widely
// cited ectopic-rejection heuristic. This is a simpler, fully-deterministic
// approximation of the same intent — remove physiologically impossible
// beat-to-beat jumps before computing HRV — at the cost of not modelling the
// missed/extra-beat insertion that Kubios does.

public enum HRVAnalyzer {

    /// Minimum plausible RR interval (ms) — 300 ms ≈ 200 bpm.
    public static let rrMinMs: Double = 300
    /// Maximum plausible RR interval (ms) — 2000 ms ≈ 30 bpm.
    public static let rrMaxMs: Double = 2000
    /// Minimum valid intervals required for a trustworthy RMSSD/SDNN.
    public static let minBeats: Int = 20
    /// Malik-style ectopic threshold: a beat deviating more than this fraction
    /// from the local median is rejected. 0.20 == 20%.
    public static let ectopicThreshold: Double = 0.20
    /// Half-width (in beats) of the local-median window used for ectopic rejection.
    /// A window of 2*radius+1 beats (5 beats at radius 2) matches the common
    /// Malik moving-window implementations.
    public static let ectopicWindowRadius: Int = 2

    /// Default ceiling on the fraction of input beats the cleaning pipeline may reject before a SPOT
    /// reading is refused as too noisy (#585). Spot-only: passed by the on-demand callers, never by the
    /// nightly windowed path. 0.35 == refuse once more than 35% of beats were dropped as out-of-range or
    /// ectopic, even if `minBeats` clean intervals survive — a quiet honesty gate on a short, live capture.
    public static let defaultSpotMaxRejectedFraction: Double = 0.35

    /// Result of an HRV computation over a window.
    public struct HRVResult: Equatable, Sendable {
        /// RMSSD in milliseconds, or nil when too few valid beats.
        public let rmssd: Double?
        /// SDNN (sample SD, ddof=1) in milliseconds, or nil when too few valid beats.
        public let sdnn: Double?
        /// Mean NN interval (ms) over the cleaned beats, or nil.
        public let meanNN: Double?
        /// pNN50: % of successive |ΔNN| > 50 ms, or nil.
        public let pnn50: Double?
        /// Count of RR intervals supplied to the analysis (before cleaning).
        public let nInput: Int
        /// Count of clean NN intervals after range + ectopic filtering.
        public let nClean: Int

        public init(rmssd: Double?, sdnn: Double?, meanNN: Double?, pnn50: Double?,
                    nInput: Int, nClean: Int) {
            self.rmssd = rmssd
            self.sdnn = sdnn
            self.meanNN = meanNN
            self.pnn50 = pnn50
            self.nInput = nInput
            self.nClean = nClean
        }

        /// An empty/insufficient-data result that preserves the input count.
        static func empty(nInput: Int) -> HRVResult {
            HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil,
                      nInput: nInput, nClean: 0)
        }
    }

    // MARK: - Primitive Task Force statistics (no filtering)

    /// Task Force (1996) RMSSD over already-clean NN intervals (ms). Returns nil
    /// when fewer than 2 values (no successive differences). No filtering applied.
    public static func rmssdRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<nn.count {
            let d = nn[i] - nn[i - 1]
            sumSq += d * d
        }
        return (sumSq / Double(nn.count - 1)).squareRoot()
    }

    /// Sample standard deviation (ddof = 1) of NN intervals (ms). Returns nil for
    /// fewer than 2 values. Matches neurokit2 HRV_SDNN. No filtering applied.
    public static func sdnnRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        let mean = nn.reduce(0, +) / Double(nn.count)
        var ss = 0.0
        for v in nn { let d = v - mean; ss += d * d }
        return (ss / Double(nn.count - 1)).squareRoot()
    }

    // MARK: - Cleaning

    /// Range filter: keep only intervals in [rrMinMs, rrMaxMs], preserving order.
    public static func rangeFilter(_ rr: [Double]) -> [Double] {
        rr.filter { $0 >= rrMinMs && $0 <= rrMaxMs }
    }

    /// Malik-style ectopic rejection: drop any beat that deviates from its local
    /// median by more than `ectopicThreshold` (20%). The local median is taken
    /// over a centered window of `2*ectopicWindowRadius+1` beats (excluding the
    /// beat under test). Beats with too small a neighbourhood are kept.
    ///
    /// NOTE: this replaces neurokit2's Kubios classifier (see file header).
    public static func rejectEctopic(_ nn: [Double]) -> [Double] {
        guard nn.count > ectopicWindowRadius else { return nn }
        var kept: [Double] = []
        kept.reserveCapacity(nn.count)
        for i in 0..<nn.count {
            let lo = max(0, i - ectopicWindowRadius)
            let hi = min(nn.count - 1, i + ectopicWindowRadius)
            var neighbours: [Double] = []
            neighbours.reserveCapacity(hi - lo)
            for j in lo...hi where j != i { neighbours.append(nn[j]) }
            guard neighbours.count >= 2 else { kept.append(nn[i]); continue }
            let med = median(neighbours)
            if med <= 0 { kept.append(nn[i]); continue }
            let deviation = abs(nn[i] - med) / med
            if deviation <= ectopicThreshold {
                kept.append(nn[i])
            }
            // else: drop this beat as ectopic.
        }
        return kept
    }

    /// Full clean: range filter → ectopic rejection. Returns the clean NN series.
    public static func cleanRR(_ rr: [Double]) -> [Double] {
        rejectEctopic(rangeFilter(rr))
    }

    // MARK: - Windowed analysis

    /// Compute HRV (RMSSD/SDNN/meanNN/pNN50) over the RR intervals whose ts falls
    /// in [windowStart, windowEnd] (inclusive). Pass nil bounds to use all rows.
    ///
    /// Applies the range filter, Malik ectopic rejection, then requires
    /// `minBeats` clean intervals; otherwise returns an empty result.
    public static func analyze(_ rr: [RRInterval],
                               windowStart: Int? = nil,
                               windowEnd: Int? = nil) -> HRVResult {
        let inWindow = rr.filter { sample in
            if let s = windowStart, sample.ts < s { return false }
            if let e = windowEnd, sample.ts > e { return false }
            return true
        }
        let raw = inWindow.map { Double($0.rrMs) }
        return analyze(rawRR: raw)
    }

    /// Compute HRV from raw RR-interval values (ms), applying the full cleaning
    /// pipeline. Returns an empty result when fewer than `minBeats` survive.
    ///
    /// - Parameter maxRejectedFraction: SPOT-ONLY honesty gate (#585). When non-nil, the reading is ALSO
    ///   refused (empty result) if the fraction of input beats dropped by cleaning exceeds this value —
    ///   even when `minBeats` clean intervals survive — because a short live capture that threw away most
    ///   of its beats is too noisy to trust. nil (the default, and what the NIGHTLY windowed path passes)
    ///   skips the gate entirely, so the nightly RMSSD is byte-identical to before this parameter existed.
    public static func analyze(rawRR: [Double], maxRejectedFraction: Double? = nil) -> HRVResult {
        let nInput = rawRR.count
        let clean = cleanRR(rawRR)
        guard clean.count >= minBeats else {
            return .empty(nInput: nInput)
        }
        // Spot-only: refuse when too large a fraction of beats was noise (out-of-range or ectopic). Only
        // applied when a ceiling is supplied; a guard against nInput == 0 is implicit (clean ≥ minBeats > 0).
        if let maxRejectedFraction, nInput > 0 {
            let rejectedFraction = 1.0 - Double(clean.count) / Double(nInput)
            if rejectedFraction > maxRejectedFraction {
                return .empty(nInput: nInput)
            }
        }
        let rmssd = rmssdRaw(clean)
        let sdnn = sdnnRaw(clean)
        let mean = clean.reduce(0, +) / Double(clean.count)

        // pNN50 over the clean NN series.
        var nn50 = 0
        for i in 1..<clean.count where abs(clean[i] - clean[i - 1]) > 50.0 { nn50 += 1 }
        let pnn50 = Double(nn50) / Double(clean.count - 1) * 100.0

        return HRVResult(rmssd: rmssd, sdnn: sdnn, meanNN: mean, pnn50: pnn50,
                         nInput: nInput, nClean: clean.count)
    }

    // MARK: - Rolling / windowed rMSSD timeline (#803)

    /// One windowed rMSSD point: the rMSSD (ms) over the trailing `windowSec` of R-R intervals ending at
    /// `ts` (wall-clock unix seconds). This is an HONEST windowed rMSSD, NOT a single "HRV" number for the
    /// night - the .hrv timeline plots a point per emitted window so an autonomic-tone report (#803) shows
    /// rMSSD MOVING across the session instead of one opaque figure.
    public struct RollingRmssdPoint: Equatable, Sendable {
        /// Wall-clock unix seconds of the last R-R interval folded into this window (the window's right edge).
        public let ts: Int
        /// rMSSD (ms) over the cleaned R-R intervals inside the trailing window.
        public let rmssd: Double
        public init(ts: Int, rmssd: Double) { self.ts = ts; self.rmssd = rmssd }
    }

    /// Pure rolling/windowed rMSSD over an R-R series (#803). For each input interval, the window is the
    /// trailing `windowSec` seconds ending at that interval's `ts`; the window's R-R values are cleaned with
    /// the SAME range filter + Malik ectopic rejection the nightly path uses (`cleanRR`), and a point is
    /// emitted only when at least `minBeatsPerWindow` clean intervals survive (so a sparse / artifact-heavy
    /// window emits nothing rather than a noisy spike). The result is one `(ts, rMSSD)` per qualifying
    /// window, in input order.
    ///
    /// - Parameters:
    ///   - rr: the R-R intervals (each carries its own wall-clock `ts` and `rrMs`). Need not be pre-sorted;
    ///     sorted ascending by `ts` internally so the trailing window is well-defined.
    ///   - windowSec: the trailing window width in seconds (e.g. 120 for a 2-minute rMSSD).
    ///   - stepSec: emit at most one point per this many seconds of advance (a thinning stride so a 1 Hz
    ///     stream does not emit a point per beat). 0 (the default) emits a point at every interval.
    ///   - minBeatsPerWindow: minimum clean intervals a window needs to emit a point. Defaults to a small
    ///     floor (8) because a short window legitimately holds far fewer beats than the nightly `minBeats`.
    public static func rollingRmssd(rr: [RRInterval],
                                    windowSec: Int,
                                    stepSec: Int = 0,
                                    minBeatsPerWindow: Int = 8) -> [RollingRmssdPoint] {
        guard windowSec > 0, rr.count >= minBeatsPerWindow else { return [] }
        let sorted = rr.sorted { $0.ts < $1.ts }
        var out: [RollingRmssdPoint] = []
        var lastEmitTs: Int? = nil
        var left = 0   // index of the oldest interval still inside the trailing window
        for right in 0..<sorted.count {
            let edgeTs = sorted[right].ts
            // Advance the left edge so [left, right] spans only the trailing `windowSec` ending at edgeTs.
            while left < right && edgeTs - sorted[left].ts > windowSec { left += 1 }
            // Thinning stride: skip emitting until at least `stepSec` has passed since the last emitted point.
            if stepSec > 0, let last = lastEmitTs, edgeTs - last < stepSec { continue }
            // Clean the window's raw R-R values with the shared range + Malik ectopic pipeline, then
            // require enough survivors before trusting a windowed rMSSD.
            let windowRaw = sorted[left...right].map { Double($0.rrMs) }
            let clean = cleanRR(windowRaw)
            guard clean.count >= minBeatsPerWindow, let r = rmssdRaw(clean) else { continue }
            out.append(RollingRmssdPoint(ts: edgeTs, rmssd: r))
            lastEmitTs = edgeTs
        }
        return out
    }

    // MARK: - Helpers

    /// Median of a non-empty array. (Caller guarantees non-empty.)
    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        let n = s.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
