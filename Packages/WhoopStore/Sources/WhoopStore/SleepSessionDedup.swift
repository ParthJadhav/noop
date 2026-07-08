import Foundation

/// Overlap-aware de-duplication of banked sleep sessions (#899).
///
/// An unstable strap clock can re-bank the SAME night's raw data under a shifted timebase across
/// syncs, so successive analyze passes detect the night at shifted bounds and the sleepSession
/// table accumulates two (or more) OVERLAPPING copies of one night under different `startTs` keys.
/// The exact (deviceId, startTs) primary-key upsert cannot collapse them (the keys differ), day
/// assignment then keys the stale copy to the wrong wake day, and Charge/Rest pin to the old night.
///
/// This is the shared collapse rule, applied wherever banked sessions are assembled before day
/// assignment / scoring (habitual-midsleep learning, band sleep-state consumption, and the
/// post-upsert store heal in IntelligenceEngine). Pure + deterministic so it is unit-tested
/// directly and the Kotlin twin (`com.noop.analytics.SleepSessionDedup`) mirrors it byte-for-byte.
public enum SleepSessionDedup {

    /// Absolute overlap (seconds) at or above which two sessions are copies of the same night.
    /// On one honest timeline two REAL sleeps can never overlap at all; material overlap only
    /// arises from re-detected bound drift or a timebase-shifted re-bank. 30 min keeps the rule
    /// conservative at the seams: sub-30-min grazes from boundary jitter are never collapsed.
    public static let minOverlapSeconds = 30 * 60

    /// Fractional overlap of the SHORTER session at or above which two sessions are duplicates.
    /// Catches a short duplicate fragment swallowed by a longer copy of the same night even when
    /// the absolute overlap is under the 30 min bar (e.g. a 40 min fragment 60% inside the night).
    public static let minOverlapFractionOfShorter = 0.5

    /// Seconds of overlap between the two sessions' EFFECTIVE spans (edited onsets honoured,
    /// mirroring how display / day assignment place the block). 0 when disjoint.
    static func overlapSeconds(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Int {
        max(0, min(a.endTs, b.endTs) - max(a.effectiveStartTs, b.effectiveStartTs))
    }

    /// True when `a` and `b` are overlapping copies of the same night: overlap of at least
    /// `minOverlapSeconds` absolute, OR at least `minOverlapFractionOfShorter` of the shorter
    /// session's duration. Both terms use only (effectiveStartTs, endTs), the only time fields
    /// the data model carries (there is no banked-at column to compare).
    public static func isDuplicate(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Bool {
        let overlap = overlapSeconds(a, b)
        guard overlap > 0 else { return false }
        if overlap >= minOverlapSeconds { return true }
        let shorter = min(max(a.endTs - a.effectiveStartTs, 0), max(b.endTs - b.effectiveStartTs, 0))
        return shorter > 0 && Double(overlap) >= minOverlapFractionOfShorter * Double(shorter)
    }

    /// Collapse overlapping duplicates to one canonical survivor per night, deterministically.
    ///
    /// Canonical preference, highest first:
    ///   1. `userEdited`: a hand-corrected night is never dropped (matching the engine's existing
    ///      edited-window upsert guard, where the user's correction always outranks re-detection).
    ///   2. Bank recency: `startTs` in `freshStarts`. The row model has no banked-at column, so
    ///      recency is witnessed by the CALLER passing the keys it banked this pass; the freshly
    ///      detected copy reflects the strap's current timebase and is the truth to keep.
    ///   3. Longest effective duration: the fullest capture of the night.
    ///   4. Latest endTs, then latest startTs: a stable total order so ties break the same way
    ///      on every run and platform.
    ///
    /// Greedy sweep in preference order: a session is kept unless it overlap-duplicates an
    /// already-kept one (edited rows are exempt and always kept). Both outputs are sorted by
    /// startTs. Read-side callers with no bank witness pass no `freshStarts`.
    public static func dedupe(_ sessions: [CachedSleepSession], freshStarts: Set<Int> = [])
        -> (kept: [CachedSleepSession], dropped: [CachedSleepSession]) {
        guard sessions.count > 1 else { return (sessions, []) }
        func rank(_ s: CachedSleepSession) -> (Int, Int, Int, Int, Int) {
            (s.userEdited ? 1 : 0,
             freshStarts.contains(s.startTs) ? 1 : 0,
             s.endTs - s.effectiveStartTs,
             s.endTs,
             s.startTs)
        }
        let ordered = sessions.sorted { rank($0) > rank($1) }
        var kept: [CachedSleepSession] = []
        var dropped: [CachedSleepSession] = []
        for s in ordered {
            if !s.userEdited, kept.contains(where: { isDuplicate($0, s) }) {
                dropped.append(s)
            } else {
                kept.append(s)
            }
        }
        return (kept.sorted { $0.startTs < $1.startTs },
                dropped.sorted { $0.startTs < $1.startTs })
    }
}
