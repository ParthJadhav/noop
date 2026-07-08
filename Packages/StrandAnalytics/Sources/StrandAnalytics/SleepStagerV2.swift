import Foundation
import WhoopProtocol

// SleepStagerV2.swift — an OPT-IN, EXPERIMENTAL alternative sleep-staging recipe, offered ALONGSIDE the
// shipped `SleepStager` (V1) rather than replacing it. V1 stays the default and is UNTOUCHED.
//
// Reimplemented clean from the contributor recipe in NoopApp/noop PR #600 (sunny-noop). We took only the
// per-session STAGING engine, not the CLI runner the PR shipped with it. Session DETECTION (the in-bed
// `[start, end]` spans) still comes entirely from V1 — this file only re-stages a window someone already
// decided is sleep, so it is a true drop-in for `SleepStager.stageSession(start:end:grav:hr:rr:resp:)`:
// SAME signature, SAME `[StageSegment]` return shape.
//
// HONEST HEDGING (same spirit as V1, plus the PR's own caveat): these stages are APPROXIMATIONS, not
// PSG-validated, not medical advice. The recipe was validated by its author on a SINGLE subject (n=1, 7
// nights) against a commercial reference — it recovered deep/REM noticeably better than V1 there (kappa
// ~0.06 → ~0.47), but the window sizes / weights may be subject-specific and need multi-subject validation
// before they can be trusted as general. That is exactly why this is opt-in and labelled experimental.
//
// Where V1 runs a percentile-band classifier + median smoothing + physiology re-imposition over a
// Cole–Kripke actigraphy grid, V2 stages each 30 s epoch from:
//   1. per-night z-scored cardiorespiratory emissions (HR / HR-variability / movement);
//   2. a per-night DEEP gate on the 11-min HR-flatness percentile (the strongest deep-vs-light separator);
//   3. a soft sleep-cycle prior (deep concentrated early; REM suppressed in the first ~12% then rising);
//   4. a peak-motion (jerk) wake gate, thresholded RELATIVE to the night's own quiescent jerk floor — so
//      it self-calibrates to the strap's gravity-decode scale and the wearer's fit, not a fixed g;
//   5. an RR-RSA respiration-regularity term (regular breathing → deep, irregular → REM);
//   6. Viterbi/HMM transition smoothing with a sticky transition matrix.
// All coefficients are fixed a-priori from sleep physiology + population base rates (NOT fit to labels).

public enum SleepStagerV2 {

    /// Build a 30 s hypnogram for `[start, end]` with this recipe and return `StageSegment`s tiling the
    /// span. DROP-IN: same signature + return type as `SleepStager.stageSession`, so a caller can switch
    /// V1↔V2 on a flag with no other change. `resp` (raw resp ADC) is accepted for signature-parity but not
    /// consumed — respiration regularity is recovered from the R-R stream (RSA), the path available on both
    /// WHOOP 4 and 5. The recipe stages "wake" naturally (no separate pre-onset / post-wake forcing).
    public static func stageSession(start: Int, end: Int, grav: [GravitySample],
                                    hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        // v7.0.2 perf (#707): stage each night AT MOST ONCE per (window, input-fingerprint). The post-sync
        // scoring loop and the self-heal restage call this with byte-identical streams across passes; without
        // the cache each call re-allocates the large per-second HR/gravity dictionaries below before
        // collapsing to a handful of `StageSegment`s. The key folds in start/end (the locked window — an edit
        // re-keys) and a fingerprint of every input stream that changes the staging (grav/hr/rr; resp is
        // accepted for signature-parity but NOT consumed by the recipe, so it is deliberately out of the key —
        // including it would only force needless misses). Only the small `[StageSegment]` is cached; the
        // multi-hour raw arrays are never retained. Bounded so the cache can't itself OOM.
        //
        // CLIP (#707, the cold-pass over-allocation): the callers pass the WHOLE multi-day decoded stream to
        // every per-night call, but `features()` never reads a sample outside [start-padLo, end+padHi] — the
        // farthest reach of any per-epoch window (the 11-min HR-flatness window: 330 s back, 390 s forward —
        // see `padLo`/`padHi` below). On the first post-sync pass (~21 nights cold) and the full-history Effort
        // rescore (up to 4000 nights cold) those out-of-window rows are what blow the per-second dictionaries
        // and the sort allocations up to OOM. The streams arrive sorted by ts, so we lower/upper-bound slice
        // each to the read window BEFORE fingerprinting and BEFORE the uncached recipe. This is output-identical
        // (we drop only rows `features()` could never touch) and it also tightens the fingerprint to the rows
        // that matter. PAD_LO/PAD_HI are the SAME values the Android twin (R1) clips with.
        let gravW = clipToWindow(grav, lo: start - Self.padLo, hi: end + Self.padHi, ts: { $0.ts })
        let hrW = clipToWindow(hr, lo: start - Self.padLo, hi: end + Self.padHi, ts: { $0.ts })
        let rrW = clipToWindow(rr, lo: start - Self.padLo, hi: end + Self.padHi, ts: { $0.ts })
        let key = V2Key(
            start: start, end: end,
            grav: StreamFingerprint.of(gravW, ts: { $0.ts }, quant: { Int(($0.x + $0.y + $0.z) * 1024) }),
            hr: StreamFingerprint.of(hrW, ts: { $0.ts }, quant: { Int($0.bpm) }),
            rr: StreamFingerprint.of(rrW, ts: { $0.ts }, quant: { Int($0.rrMs) }))
        return stageCache.value(key) {
            stageSessionUncached(start: start, end: end, grav: gravW, hr: hrW, rr: rrW, resp: resp)
        }
    }

    /// Farthest seconds, relative to an epoch, that `features()` reads any input — i.e. the largest backward /
    /// forward reach of any per-epoch window. The 11-min HR-flatness window dominates both directions
    /// (`stdOfSeconds(e - 330, e + 30 + 360)` reads `[e-330, e+390)`); the 5-min window (`[e-150, e+180)`) and
    /// the RSA beat window (`[e-90, e+120)`) are strictly inside it. Epochs tile `[start, end)`, so no feature
    /// can read before `start - padLo` or at/after `end + padHi`. MUST match the Android twin (R1).
    static let padLo = 330   // backward reach: 11-min window's `e - 330`
    static let padHi = 390   // forward reach: 11-min window's `e + 30 + 360`

    /// Slice a ts-sorted stream to `[lo, hi)` with a lower/upper-bound pair (O(log n) bounds + one copy of the
    /// kept rows). Returns a contiguous sub-slice as an `Array`. Loss-free for the recipe: every row outside
    /// the window is one `features()` provably never touches.
    private static func clipToWindow<T>(_ samples: [T], lo: Int, hi: Int, ts: (T) -> Int) -> [T] {
        if samples.isEmpty { return samples }
        // Already inside the window in full → avoid the copy (the common single-night case).
        if ts(samples[0]) >= lo && ts(samples[samples.count - 1]) < hi { return samples }
        // lowerBound: first index with ts >= lo.
        var l = 0, h = samples.count
        while l < h { let m = (l + h) / 2; if ts(samples[m]) < lo { l = m + 1 } else { h = m } }
        let start = l
        // upperBound: first index with ts >= hi (exclusive upper, matching the half-open read windows).
        l = start; h = samples.count
        while l < h { let m = (l + h) / 2; if ts(samples[m]) < hi { l = m + 1 } else { h = m } }
        if start == 0 && l == samples.count { return samples }
        return Array(samples[start..<l])
    }

    /// Cache key = locked window + per-stream fingerprints of the inputs the recipe actually reads.
    private struct V2Key: Hashable {
        let start: Int; let end: Int
        let grav: StreamFingerprint; let hr: StreamFingerprint; let rr: StreamFingerprint
    }

    /// ≈ a couple of weeks of distinct nights (incl. re-staged edits); FIFO-evicted, result-only.
    private static let stageCache = AnalyticsMemoCache<V2Key, [StageSegment]>(capacity: 24)

    /// The unchanged staging recipe. Split out verbatim from `stageSession` so the public entry can memoize
    /// in front of it; behaviour is byte-identical (a cache miss runs exactly this).
    private static func stageSessionUncached(start: Int, end: Int, grav: [GravitySample],
                                             hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        // Sort defensively so the windowed features behave regardless of caller ordering (V1's stageSession
        // assumes its callers pass roughly-sorted streams; we make no such assumption here).
        let gravS = grav.sorted { $0.ts < $1.ts }
        let hrS = hr.sorted { $0.ts < $1.ts }
        let rrS = rr.sorted { $0.ts < $1.ts }

        let feats = features(start: start, end: end, grav: gravS, hr: hrS, rr: rrS)
        if feats.isEmpty { return [StageSegment(start: start, end: end, stage: "light")] }
        let labels = stageEpochs(feats)

        // Tile [start, end] with one segment per staged epoch. The first segment back-fills [start, firstEpoch)
        // and the last extends to `end`; an interior coverage gap is carried by the preceding label. "awake"
        // is renamed to the canonical "wake" used by V1 / StageSegment.
        var segments: [StageSegment] = []
        for (i, f) in feats.enumerated() {
            let stage = labels[i] == "awake" ? "wake" : labels[i]
            let segStart = i == 0 ? start : f.start
            let segEnd = i == feats.count - 1 ? end : feats[i + 1].start
            if let last = segments.last, last.stage == stage {
                segments[segments.count - 1].end = segEnd
            } else {
                segments.append(StageSegment(start: segStart, end: segEnd, stage: stage))
            }
        }
        return segments
    }

    // MARK: - Recipe constants (all fixed a-priori — NOT fit to labels)

    static let stageNames = ["deep", "rem", "light", "awake"]

    /// Population sleep-architecture base rates as log-priors (adult TST ≈ light 50 / deep 18 / rem 22 /
    /// waso 10 %). Calibrates the boundary so light wins weak-evidence epochs.
    static let baseLogPrior: [String: Double] = [
        "light": log(0.50), "deep": log(0.18), "rem": log(0.22), "awake": log(0.10)]

    /// Deep is eligible only in the night's lowest ~20 % HR-flatness epochs (≈ deep base rate + margin).
    static let deepGateThresh = 0.20
    static let deepGateSlope = 5.0

    /// Motion thresholds are RELATIVE to each night's own quiescent jerk floor (the median per-second
    /// gravity-jerk over the in-bed session), NOT an absolute g. Self-calibrates to the strap's
    /// gravity-decode scale and the wearer's fit.
    static let jerkFloorMoveMult = 38.0  // a per-second jerk counts as "moving" above floor × this
    static let jerkFloorGateMult = 55.0  // wake-boost when an epoch's peak jerk exceeds floor × this
    static let motionGateBoost = 2.0

    /// Weight of the RSA respiration-regularity term (regular → deep, irregular → REM).
    static let respWeight = 0.6

    /// Transition matrix (rows = from, cols = to). Self-transitions dominate; deep↔rem rare; wake mostly
    /// to/from light. A priori, not fit.
    static let transition: [String: [String: Double]] = [
        "deep":  ["deep": 0.90, "rem": 0.005, "light": 0.09, "awake": 0.005],
        "rem":   ["deep": 0.005, "rem": 0.88, "light": 0.10, "awake": 0.015],
        "light": ["deep": 0.06, "rem": 0.06, "light": 0.85, "awake": 0.03],
        "awake": ["deep": 0.01, "rem": 0.02, "light": 0.27, "awake": 0.70]]

    /// One 30 s epoch's recipe features. Optionals are "no measurement"; the z-score / percentile treat a
    /// missing value as the neutral centre so a sparse channel never blocks a stage.
    struct Epoch {
        let start: Int          // epoch start (unix seconds, multiple of 30)
        let hr: Double?         // epoch-mean HR (bpm)
        let hrVar: Double?      // std of per-second HR over a centred 5-min window
        let hrFlat11: Double?   // std of per-second HR over a centred 11-min window (deep/light separator)
        let moveFrac: Double    // fraction of in-epoch per-second jerks above the night-relative move threshold
        let jerkMax: Double     // peak in-epoch per-second jerk (g) — wake is bursty
        let respReg: Double?    // RSA spectral peakedness in the 0.15–0.40 Hz band (breathing regularity)
        let clock: Double       // time-of-night fraction in [0, 1]
        let jerkScale: Double   // night quiescent jerk floor (median per-second jerk over the session)
    }

    // MARK: - Feature extraction

    /// Build the per-epoch recipe features over a 30 s wall-clock-aligned grid covering [start, end].
    /// Streams are the sorted streams already clipped (by `stageSession`) to `[start-padLo, end+padHi]` — a
    /// superset of every read window — so the 5-/11-min HR windows and the RSA beat window still reach to the
    /// session edges exactly as before; only rows no window could touch were dropped.
    static func features(start: Int, end: Int, grav: [GravitySample],
                         hr: [HRSample], rr: [RRInterval]) -> [Epoch] {
        if end <= start { return [] }
        let span = Double(max(1, end - start))

        // Per-second aggregation (one value per integer second; mean when a second carries several samples).
        var hrSum = [Int: Double](), hrCnt = [Int: Int]()
        for s in hr { hrSum[s.ts, default: 0] += Double(s.bpm); hrCnt[s.ts, default: 0] += 1 }
        var secHR = [Int: Double](); secHR.reserveCapacity(hrSum.count)
        for (k, v) in hrSum { secHR[k] = v / Double(hrCnt[k]!) }

        var gxSum = [Int: Double](), gySum = [Int: Double](), gzSum = [Int: Double](), gCnt = [Int: Int]()
        for g in grav {
            gxSum[g.ts, default: 0] += g.x; gySum[g.ts, default: 0] += g.y
            gzSum[g.ts, default: 0] += g.z; gCnt[g.ts, default: 0] += 1
        }
        var secG = [Int: (Double, Double, Double)](); secG.reserveCapacity(gCnt.count)
        for (k, c) in gCnt { let d = Double(c); secG[k] = (gxSum[k]! / d, gySum[k]! / d, gzSum[k]! / d) }

        // R-R values bucketed by second (for the RSA respiration window).
        var rrBy = [Int: [Double]]()
        for r in rr { rrBy[r.ts, default: []].append(Double(r.rrMs)) }

        // PREFIX SUMS over the per-second HR grid (#707). Every epoch evaluates a 5-min AND an 11-min centred
        // std window; the old `stdOfSeconds` re-scanned and re-allocated a `vals` array of up to ~660 entries
        // PER window PER epoch — O(window) each, the dominant transient alloc in the cold-stage path. We build
        // dense prefix arrays of (count, Σv, Σv²) over the present seconds ONCE, then each window is an O(1)
        // range query. The std stays population (÷n) with the SAME `<2 present → nil` semantics, and on every
        // real fixture the staged hypnogram is byte-identical (the second-moment is the algebraic expansion
        // `Σ(v-m)²` = `Σv² − 2m·Σv + n·m²`, which can differ from the prior direct sum only in the last ULPs —
        // far below the margin that could flip a Viterbi label; verified label-identical on the golden nights).
        // The grid spans the present HR seconds; a window reaching past the grid simply sees fewer present
        // seconds, exactly as the old scan found no `secHR` entry there.
        let gridLo = secHR.keys.min()
        let gridHi = secHR.keys.max()
        var pCnt = [Int](), pSum = [Double](), pSq = [Double]()
        if let g0 = gridLo, let g1 = gridHi {
            let n = g1 - g0 + 1
            pCnt = [Int](repeating: 0, count: n + 1)
            pSum = [Double](repeating: 0, count: n + 1)
            pSq = [Double](repeating: 0, count: n + 1)
            for i in 0..<n {
                let v = secHR[g0 + i]
                pCnt[i + 1] = pCnt[i] + (v == nil ? 0 : 1)
                pSum[i + 1] = pSum[i] + (v ?? 0)
                pSq[i + 1] = pSq[i] + (v.map { $0 * $0 } ?? 0)
            }
        }
        // Population std over the PRESENT per-second HR in `[lo, hi)`; nil when < 2 present samples (matching
        // the prior windowed scan). O(1): two prefix lookups after clamping the window to the grid.
        func stdOfSeconds(_ lo: Int, _ hi: Int) -> Double? {
            guard let g0 = gridLo, let g1 = gridHi else { return nil }
            let a = max(lo, g0) - g0
            let b = min(hi, g1 + 1) - g0
            if b <= a { return nil }
            let cnt = pCnt[b] - pCnt[a]
            if cnt < 2 { return nil }
            let n = Double(cnt)
            let sv = pSum[b] - pSum[a]
            let sq = pSq[b] - pSq[a]
            let m = sv / n
            let v = (sq - 2 * m * sv + n * m * m) / n
            return (v < 0 ? 0 : v).squareRoot()
        }

        // PASS 1 — every per-epoch quantity EXCEPT the move fraction, and pool every per-second jerk so the
        // night's quiescent jerk floor (its median) can scale the motion thresholds. moveFrac needs that
        // floor, which isn't known until the whole session has been scanned — hence two passes.
        struct Raw {
            let start: Int; let hr: Double?; let hrVar: Double?; let hrFlat11: Double?
            let jerks: [Double]; let gapSec: Int; let jerkMax: Double; let respReg: Double?; let clock: Double
        }
        var raws: [Raw] = []
        var allJerks: [Double] = []
        let firstE = ((start + 29) / 30) * 30
        var e = firstE
        while e < end {
            var hrs: [Double] = []
            var gseq: [(Double, Double, Double)] = []
            for s in e..<(e + 30) {
                if let h = secHR[s] { hrs.append(h) }
                if let g = secG[s] { gseq.append(g) }
            }
            if hrs.isEmpty && gseq.isEmpty { e += 30; continue }   // no coverage → skip the epoch

            // Movement: consecutive per-second gravity jerks within the epoch.
            var jerks: [Double] = []
            for i in 1..<max(1, gseq.count) {
                let a = gseq[i - 1], b = gseq[i]
                let dx = a.0 - b.0, dy = a.1 - b.1, dz = a.2 - b.2
                jerks.append((dx * dx + dy * dy + dz * dz).squareRoot())
            }
            allJerks.append(contentsOf: jerks)
            let jerkMax = jerks.max() ?? 0.0

            let hrMean = hrs.isEmpty ? nil : hrs.reduce(0, +) / Double(hrs.count)
            let hrVar = stdOfSeconds(e - 150, e + 30 + 150)     // 5-min centred window
            let hrFlat11 = stdOfSeconds(e - 330, e + 30 + 360)  // 11-min centred window

            // RSA respiration over a wider beat window [e-90, e+120).
            var beats: [(Double, Double)] = []
            for s in (e - 90)..<(e + 120) {
                if let vs = rrBy[s] { for v in vs { beats.append((Double(s), min(max(v, 300), 2000))) } }
            }
            beats.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            let respReg = respRegularity(beats)

            raws.append(Raw(start: e, hr: hrMean, hrVar: hrVar, hrFlat11: hrFlat11,
                            jerks: jerks, gapSec: max(1, gseq.count - 1), jerkMax: jerkMax,
                            respReg: respReg, clock: Double(e + 15 - start) / span))
            e += 30
        }

        // Night quiescent jerk floor = median of all per-second jerks (most sleep seconds are still, so the
        // median tracks the strap's noise/decode floor). Tiny epsilon when there's no motion data so the move
        // threshold collapses to ~0 rather than dividing by nothing.
        let jerkScale: Double = {
            if allJerks.isEmpty { return 1e-6 }
            let s = allJerks.sorted(); let n = s.count
            return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
        }()
        let moveThr = jerkScale * jerkFloorMoveMult

        // PASS 2 — move fraction against the night-relative threshold; carry the floor on each epoch so the
        // wake gate in stageEpochs() can be night-relative too.
        var feats: [Epoch] = []
        feats.reserveCapacity(raws.count)
        for r in raws {
            let moves = r.jerks.reduce(0) { $0 + ($1 > moveThr ? 1 : 0) }
            feats.append(Epoch(
                start: r.start, hr: r.hr, hrVar: r.hrVar, hrFlat11: r.hrFlat11,
                moveFrac: Double(moves) / Double(r.gapSec), jerkMax: r.jerkMax, respReg: r.respReg,
                clock: r.clock, jerkScale: jerkScale))
        }
        return feats
    }

    /// RSA respiration regularity: tachogram → 4 Hz resample → detrend → power spectrum → peak/sum of the
    /// 0.15–0.40 Hz (9–24 brpm) band. Returns spectral peakedness (higher = more regular breathing) or nil
    /// when there are too few beats. A direct band-limited DFT (only the ~50 in-band bins are needed).
    static func respRegularity(_ beats: [(Double, Double)]) -> Double? {
        if beats.count < 12 { return nil }
        let t0 = beats.first!.0, tN = beats.last!.0
        if tN <= t0 { return nil }
        let n = Int(ceil((tN - t0) / 0.25 - 1e-9))   // np.arange(t0, tN, 0.25) length
        if n < 16 { return nil }

        // Linear resample onto the uniform 4 Hz grid (clamped within [t0, tN]).
        var y = [Double](repeating: 0, count: n)
        var seg = 0
        for i in 0..<n {
            let t = t0 + 0.25 * Double(i)
            while seg < beats.count - 2 && beats[seg + 1].0 < t { seg += 1 }
            let ta = beats[seg].0, tb = beats[seg + 1].0
            let va = beats[seg].1, vb = beats[seg + 1].1
            y[i] = tb <= ta ? va : va + min(max((t - ta) / (tb - ta), 0), 1) * (vb - va)
        }
        let mean = y.reduce(0, +) / Double(n)
        for i in 0..<n { y[i] -= mean }

        // Band bins: f[k] = k / (n·0.25); keep 0.15 ≤ f ≤ 0.40.
        let kLo = Int(ceil(0.15 * 0.25 * Double(n)))
        let kHi = Int(floor(0.40 * 0.25 * Double(n)))
        if kHi < kLo || kLo < 0 { return nil }
        var maxP = 0.0, sumP = 0.0
        for k in kLo...kHi {
            var re = 0.0, im = 0.0
            let w = -2.0 * Double.pi * Double(k) / Double(n)
            for j in 0..<n { let a = w * Double(j); re += y[j] * cos(a); im += y[j] * sin(a) }
            let p = re * re + im * im
            sumP += p
            if p > maxP { maxP = p }
        }
        if sumP == 0 { return nil }
        return maxP / sumP
    }

    // MARK: - Recipe staging

    /// Soft sleep-cycle prior added to the log-emission: deep concentrated early (decays, never hard-wiped);
    /// REM suppressed in the first ~12 % (REM latency) then rising toward morning.
    static func cyclePrior(_ c: Double) -> [String: Double] {
        ["deep": 1.2 * max(0.0, 1.0 - c / 0.55),
         "rem": 1.0 * c - (c < 0.12 ? 3.0 : 0.0),
         "light": 0.0, "awake": 0.0]
    }

    /// Viterbi most-likely path over the per-epoch log-emissions with the sticky transition matrix and a
    /// uniform start. Ties resolve to the earlier stage in `stageNames`.
    static func viterbi(_ emSeq: [[String: Double]]) -> [String] {
        if emSeq.isEmpty { return [] }
        let logT = transition.mapValues { row in row.mapValues { log($0) } }
        var V = emSeq[0]   // uniform start
        var back: [[String: String]] = []
        for t in 1..<emSeq.count {
            var newV = [String: Double](), bp = [String: String]()
            for s in stageNames {
                var bestPrev = stageNames[0]
                var bestVal = V[bestPrev]! + logT[bestPrev]![s]!
                for p in stageNames.dropFirst() {
                    let val = V[p]! + logT[p]![s]!
                    if val > bestVal { bestVal = val; bestPrev = p }
                }
                newV[s] = bestVal + emSeq[t][s]!
                bp[s] = bestPrev
            }
            V = newV; back.append(bp)
        }
        var last = stageNames[0], lastV = V[last]!
        for s in stageNames.dropFirst() where V[s]! > lastV { lastV = V[s]!; last = s }
        var path = [last]
        for bp in back.reversed() { last = bp[last]!; path.append(last) }
        return path.reversed()
    }

    /// Run the full recipe over a night's epochs and return one stage label per epoch (incl. "awake").
    /// All normalisation (z-scores, the HR-flatness percentile) is WITHIN the night.
    static func stageEpochs(_ feats: [Epoch]) -> [String] {
        if feats.isEmpty { return [] }

        // Per-night z-score over the present values (population std; 0 std → 1 so a flat channel is neutral).
        func zfun(_ vals: [Double?]) -> (Double?) -> Double {
            let present = vals.compactMap { $0 }
            if present.isEmpty { return { _ in 0.0 } }
            let m = present.reduce(0, +) / Double(present.count)
            let sd0 = (present.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(present.count)).squareRoot()
            let sd = sd0 == 0 ? 1.0 : sd0
            return { v in v == nil ? 0.0 : (v! - m) / sd }
        }
        let zhr = zfun(feats.map { $0.hr })
        let zhv = zfun(feats.map { $0.hrVar })
        let zmv = zfun(feats.map { Optional($0.moveFrac) })
        let zrg = zfun(feats.map { $0.respReg })

        // HR-flatness percentile rank within the night (bisect_right / n), neutral 0.5 when missing.
        let fsorted = feats.compactMap { $0.hrFlat11 }.sorted()
        func fpct(_ v: Double?) -> Double {
            guard let v = v, !fsorted.isEmpty else { return 0.5 }
            var lo = 0, hi = fsorted.count
            while lo < hi { let mid = (lo + hi) / 2; if fsorted[mid] <= v { lo = mid + 1 } else { hi = mid } }
            return Double(lo) / Double(fsorted.count)
        }

        var seq: [[String: Double]] = []
        seq.reserveCapacity(feats.count)
        for f in feats {
            let zhrv = zhr(f.hr), zhvv = zhv(f.hrVar), zmvv = zmv(f.moveFrac)
            let gate = deepGateSlope * max(0.0, fpct(f.hrFlat11) - deepGateThresh)
            var em: [String: Double] = [
                "deep": -1.4 * zhvv - 0.2 * zhrv - 0.3 * zmvv - gate + baseLogPrior["deep"]!,
                "rem": 0.6 * zhvv - 0.6 * zmvv + 0.4 * zhrv + baseLogPrior["rem"]!,
                "light": baseLogPrior["light"]!,
                "awake": 1.0 * zmvv + 0.8 * zhvv + 0.4 * zhrv + baseLogPrior["awake"]!,
            ]
            let pr = cyclePrior(f.clock)
            for s in stageNames { em[s]! += pr[s]! }
            if f.jerkMax > f.jerkScale * jerkFloorGateMult { em["awake"]! += motionGateBoost }
            if let rg = f.respReg { let z = zrg(rg); em["deep"]! += respWeight * z; em["rem"]! -= respWeight * z }
            seq.append(em)
        }
        return viterbi(seq)
    }
}
