package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RespSample
import com.noop.data.RrInterval

/**
 * StagerCache.kt — a small, bounded, thread-safe memo shared by [SleepStager.stageSession] (V1) and
 * [SleepStagerV2.stageSession] (V2). (v7.0.2 / #707)
 *
 * WHY: per-night sleep staging is the single heaviest thing on the analytics model path, and it was being
 * recomputed for EVERY detected night on EVERY [IntelligenceEngine.analyzeRecent] — i.e. ~21× per post-sync
 * scoring pass, AGAIN after each sleep edit (editSleepTimes / addManualNap each re-run analyzeRecent), and
 * up to thousands of nights in one shot on the full-history Effort rescore (maxDays = 4000). With the
 * opt-in V2 recipe enabled (a per-epoch band-limited DFT + a 4-state Viterbi over the whole night) this
 * COMPUTE alone could exhaust the 256 MB Android heap post-sync, before any scroll — the traced cause of
 * the #707 OOM (2 users, Sleep V2 on).
 *
 * Staging is a PURE function of (start, end, samples), so each distinct night need only be staged ONCE.
 * This object memoizes it under a fingerprint of exactly those inputs in a bounded access-order LRU, keyed
 * per recipe ([Version]) so V1 and V2 never collide. The result: peak heap stays flat across repeated
 * passes and the staged output is byte-identical to recomputing it.
 *
 * CORRECTNESS:
 *   - The key folds in EVERY input that changes the output and nothing that can't (see [fingerprint]), so an
 *     edit always invalidates: a moved bed/wake time changes start/end; newly-banked samples change a
 *     stream's count / edge timestamps / value checksum. A stale result is therefore never returned.
 *   - The cache is BOUNDED ([MAX_NIGHTS]); an unbounded cache would just be a slower leak, defeating the
 *     point of a memory fix.
 *   - [StageSegment] is mutable (the stagers extend a trailing segment in place), so EVERY boundary into and
 *     out of the cache is a deep copy — a caller can never mutate a cached list, and a freshly-staged list
 *     handed to a caller is never the same instance the cache holds.
 */
internal object StagerCache {

    /** Which recipe produced a cached hypnogram — part of the key so V1 and V2 never alias each other. */
    enum class Version { V1, V2 }

    /**
     * A night's cache key: the staging recipe, the window, and a per-stream digest of every consumed
     * stream. The digest is (count, first-ts, last-ts, an order-independent value checksum). The checksum
     * catches an edit that swaps sample VALUES while keeping the same count + edge timestamps (e.g. a
     * re-import correcting bpm/gravity in place) — without it the cache could hand back a stale hypnogram.
     * `resp` is folded in for [Version.V1] (which consumes it) but is the neutral 0-digest for [Version.V2]
     * (which never reads it — RSA comes from `rr`), so V2 never takes a false miss on a resp-only change.
     * Equality / hashCode are the data-class defaults.
     */
    data class Key(
        val version: Version,
        val start: Long, val end: Long,
        val gN: Int, val gFirst: Long, val gLast: Long, val gSum: Long,
        val hN: Int, val hFirst: Long, val hLast: Long, val hSum: Long,
        val rN: Int, val rFirst: Long, val rLast: Long, val rSum: Long,
        val pN: Int, val pFirst: Long, val pLast: Long, val pSum: Long,
    )

    /**
     * Build the input fingerprint. O(total samples), allocation-free, and far cheaper than the staging it
     * guards. `resp` defaults to empty so the V2 caller (which never stages on resp) can omit it and land on
     * the neutral 0-digest. Value checksums are order-independent in spirit (folded with large odd
     * multipliers); the streams are sorted inside the stagers anyway, so a key collision across genuinely
     * different nights is astronomically unlikely, and a false HIT would require identical count + edge
     * timestamps + identical folded checksum — i.e. effectively the same data.
     */
    fun fingerprint(
        version: Version,
        start: Long, end: Long,
        grav: List<GravitySample>, hr: List<HrSample>, rr: List<RrInterval>,
        resp: List<RespSample> = emptyList(),
    ): Key {
        var gSum = 0L; var gFirst = 0L; var gLast = 0L
        if (grav.isNotEmpty()) {
            gFirst = grav.first().ts; gLast = grav.last().ts
            for (s in grav) {
                gSum = gSum * 1_000_003 + s.ts * 31
                gSum = gSum * 1_000_003 + java.lang.Double.doubleToRawLongBits(s.x)
                gSum = gSum * 1_000_003 + java.lang.Double.doubleToRawLongBits(s.y)
                gSum = gSum * 1_000_003 + java.lang.Double.doubleToRawLongBits(s.z)
            }
        }
        var hSum = 0L; var hFirst = 0L; var hLast = 0L
        if (hr.isNotEmpty()) {
            hFirst = hr.first().ts; hLast = hr.last().ts
            for (s in hr) hSum = hSum * 1_000_003 + s.ts * 31 + s.bpm
        }
        var rSum = 0L; var rFirst = 0L; var rLast = 0L
        if (rr.isNotEmpty()) {
            rFirst = rr.first().ts; rLast = rr.last().ts
            for (s in rr) rSum = rSum * 1_000_003 + s.ts * 31 + s.rrMs
        }
        var pSum = 0L; var pFirst = 0L; var pLast = 0L
        if (resp.isNotEmpty()) {
            pFirst = resp.first().ts; pLast = resp.last().ts
            for (s in resp) pSum = pSum * 1_000_003 + s.ts * 31 + s.raw
        }
        return Key(
            version, start, end,
            grav.size, gFirst, gLast, gSum,
            hr.size, hFirst, hLast, hSum,
            rr.size, rFirst, rLast, rSum,
            resp.size, pFirst, pLast, pSum,
        )
    }

    /** Bound: 64 staged nights. ~3× the 21-night analyzeRecent window — comfortably covers a multi-night
     *  offload pass plus the few extra a sleep edit re-touches, with headroom for both V1 and V2 keys —
     *  yet tiny (a night is a handful of StageSegments). Access-order LRU so the hottest nights survive. */
    private const val MAX_NIGHTS = 64

    private val cache: LinkedHashMap<Key, List<StageSegment>> =
        object : LinkedHashMap<Key, List<StageSegment>>(16, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, List<StageSegment>>): Boolean =
                size > MAX_NIGHTS
        }
    private val lock = Any()

    fun get(key: Key): List<StageSegment>? = synchronized(lock) { cache[key] }

    fun put(key: Key, value: List<StageSegment>) {
        // Store a defensive copy so the entry is never the same instance a caller holds (StageSegment is
        // mutable; a caller extending start/end in place would otherwise corrupt the cache).
        synchronized(lock) { cache[key] = copyOf(value) }
    }

    /** Deep copy of a hypnogram (StageSegment is mutable, so every cache boundary copies). */
    fun copyOf(segs: List<StageSegment>): List<StageSegment> =
        ArrayList<StageSegment>(segs.size).apply {
            for (s in segs) add(StageSegment(start = s.start, end = s.end, stage = s.stage))
        }
}
