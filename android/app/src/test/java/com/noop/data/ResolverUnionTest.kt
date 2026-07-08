package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * RESOLVER + SLEEP-BLOCK UNION (#1008, the #814 read-spine union joined to the two seams it missed):
 *
 * After a strap remove+re-add the Collector writes LIVE data under a fresh "whoop-<uuid>" id while the
 * WHOOP-export import + the engine's computed write target stay anchored on the CANONICAL
 * "my-whoop"/"my-whoop-noop". Two reads never joined the union model the rest of the repository uses:
 *
 *   1. [WhoopRepository.sourceCandidates] , the daily-metric resolver's strap-preferred candidate list
 *      was [strap, strap-noop, apple] with NO canonical fallback, so a caller threading the ACTIVE id
 *      orphaned the canonical history (and a caller passing the canonical default orphaned the live id).
 *      Fixed by appending the canonical pair, mirroring Swift Repository.sourceCandidates.
 *   2. [WhoopRepository.dedupSleepBlocks] , the union sleep reads ([WhoopRepository.sleepSessionsUnion] /
 *      habitualMidsleepSec) concatenate active + canonical blocks and must drop only EXACT-duplicate
 *      (startTs, endTs) twins, active copy surviving. Mirrors Swift Repository.dedupBlocks.
 *
 * These exercise the PURE companion seams only (no Room, plain JVM), complementing [ReadSpineUnionTest],
 * which covers the daily-metric union ids/merge. Stuck-sleep cluster: #1014 / #1009.
 */
class ResolverUnionTest {

    private val canonical = "my-whoop"
    private val reAdded = "whoop-ABC123" // the id a re-added strap gets (whoop-<uuid>)

    /** Candidate SOURCE ids for a strap-preferred read ("my-whoop" preferred, as every UI caller passes). */
    private fun candidateSources(strap: String, key: String = "recovery") =
        WhoopRepository.sourceCandidates(key, canonical, strap).map { it.source }

    // --- sourceCandidates: the resolver's #814 union ---

    /** Single-WHOOP install: uniqued() collapses the active + canonical pairs to ONE pair, so the
     *  candidate list , and therefore every resolver read , is byte-identical to the pre-fix behaviour. */
    @Test
    fun singleDeviceCandidatesCollapseToCanonicalPair() {
        assertEquals(listOf("my-whoop", "my-whoop-noop"), candidateSources(strap = canonical))
    }

    /** After a re-add the resolver tries the ACTIVE id + its computed sibling FIRST (live/measured wins
     *  per day), then falls back to the canonical "my-whoop"/"my-whoop-noop" so daily metrics + scores
     *  banked BEFORE the re-add still resolve. Before #1008 the canonical fallback was missing. */
    @Test
    fun reAddCandidatesUnionActiveThenCanonical() {
        assertEquals(
            listOf(reAdded, "$reAdded-noop", "my-whoop", "my-whoop-noop"),
            candidateSources(strap = reAdded),
        )
    }

    /** A vital with a declared Apple-Health mapping appends the Apple candidate LAST , after the whole
     *  WHOOP union , so a real Apple export fills only days no WHOOP source covers. The Apple candidate
     *  carries the MAPPED key ("rhr" → "resting_hr"), not the WHOOP key. */
    @Test
    fun appleFallbackAppendsLastWithMappedKey() {
        val candidates = WhoopRepository.sourceCandidates("rhr", canonical, reAdded)
        assertEquals(
            listOf(reAdded, "$reAdded-noop", "my-whoop", "my-whoop-noop", "apple-health"),
            candidates.map { it.source },
        )
        assertEquals("resting_hr", candidates.last().key)
    }

    /** A derived score with NO Apple mapping never grows an Apple candidate , the resolver must not
     *  fabricate a cross-source fallback for a WHOOP-only composite. */
    @Test
    fun scoreWithNoAppleMappingGetsNoAppleCandidate() {
        assertNull(candidateSources(strap = reAdded, key = "recovery").find { it == "apple-health" })
    }

    /** The Apple-preferred and single-source paths are UNTOUCHED by the union fix: Apple still resolves
     *  [apple, health-connect] (+ the computed strap sibling only for the two totals the strap genuinely
     *  estimates), and any other source resolves itself only. */
    @Test
    fun applePreferredAndSingleSourcePathsUnchanged() {
        assertEquals(
            listOf("apple-health", "health-connect"),
            WhoopRepository.sourceCandidates("hrv", "apple-health", reAdded).map { it.source },
        )
        assertEquals(
            listOf("apple-health", "health-connect", "$reAdded-noop"),
            WhoopRepository.sourceCandidates("steps", "apple-health", reAdded).map { it.source },
        )
        assertEquals(
            listOf("nutrition-csv"),
            WhoopRepository.sourceCandidates("calories_in", "nutrition-csv", reAdded).map { it.source },
        )
    }

    // --- dedupSleepBlocks: the sleep-block union's exact-twin drop ---

    private fun block(source: String, start: Long, end: Long) =
        SleepSession(deviceId = source, startTs = start, endTs = end)

    /** The same physical night recorded under BOTH union ids collapses to ONE block, and the FIRST-seen
     *  (active-strap, since the callers pass active-first lists) copy survives , so the learner never
     *  double-weights a night and the live row wins. */
    @Test
    fun exactDuplicateNightKeepsActiveCopyOnly() {
        val night = 1_750_000_000L to 1_750_028_800L
        val deduped = WhoopRepository.dedupSleepBlocks(
            listOf(
                block(reAdded, night.first, night.second), // active first, exactly as sleepSessionsUnion orders
                block(canonical, night.first, night.second),
            ),
        )
        assertEquals(1, deduped.size)
        assertEquals("the active-strap copy survives", reAdded, deduped[0].deviceId)
    }

    /** Genuinely DISTINCT blocks all survive , a nap and a main night on the same day are never
     *  collapsed (the union drops twins only, the per-day merge stays the caller's). */
    @Test
    fun distinctBlocksSurviveNapPlusMainNight() {
        val deduped = WhoopRepository.dedupSleepBlocks(
            listOf(
                block(reAdded, 1_750_000_000L, 1_750_028_800L), // main night
                block(reAdded, 1_750_050_000L, 1_750_053_600L), // afternoon nap
                block(canonical, 1_750_090_000L, 1_750_118_800L), // canonical-only older night
            ),
        )
        assertEquals(3, deduped.size)
    }

    /** A block sharing only its START (an end-drifted re-detection) is NOT a twin , both survive, since
     *  the dedup keys on the exact (startTs, endTs) pair, matching Swift's "\(startTs)-\(endTs)" key. */
    @Test
    fun sameStartDifferentEndIsNotATwin() {
        val deduped = WhoopRepository.dedupSleepBlocks(
            listOf(
                block(reAdded, 1_750_000_000L, 1_750_028_800L),
                block(canonical, 1_750_000_000L, 1_750_030_000L),
            ),
        )
        assertEquals(2, deduped.size)
    }
}
