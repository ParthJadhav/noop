package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the [SleepStager.detectSleep] memo (#707 parity with the Swift detectSleepCache).
 *
 * The load-bearing property is fingerprint COMPLETENESS: the cache is only safe if a change to ANY
 * keyed input re-keys to a fresh compute — a false hit would hand back the wrong night's sleep. The
 * fingerprint tests assert exactly that per perturbation class (value / ts / count). Given a complete,
 * deterministic fingerprint, plain Map semantics guarantee the second identical call IS a memo hit, so
 * the end-to-end tests pin what a hit must look like: byte-identical to the uncached compute (the
 * traced path bypasses the memo, so it doubles as the ground truth here), fresh [StageSegment]
 * instances (never the cache's own), and immune to a caller mutating a previously returned result
 * in place (the StagerCache copy-discipline lesson, which detectSleep inherits because Kotlin's
 * StageSegment is mutable where Swift's struct is not).
 */
class SleepStagerDetectMemoTest {

    // ── streamFingerprint completeness ────────────────────────────────────────────────────────────

    private data class S(val ts: Long, val v: Long)

    private fun fp(list: List<S>) = SleepStager.streamFingerprint(list, { it.ts }) { it.v }

    private val base = (0 until 300).map { S(ts = 1_750_000_000L + it, v = (it % 41).toLong()) }

    @Test
    fun identicalStreamsFoldIdentically() {
        // Distinct instances, same data → same fingerprint: the genuine-hit half of the contract.
        assertEquals(fp(base), fp(base.map { it.copy() }))
    }

    @Test
    fun interiorValueChangeReKeys() {
        // An in-place value edit (a re-import correcting one sample) must not alias onto the stale entry.
        val perturbed = base.toMutableList().also { it[137] = it[137].copy(v = it[137].v + 1) }
        assertNotEquals(fp(base), fp(perturbed))
    }

    @Test
    fun interiorTimestampChangeReKeys() {
        val perturbed = base.toMutableList().also { it[64] = it[64].copy(ts = it[64].ts + 1) }
        assertNotEquals(fp(base), fp(perturbed))
    }

    @Test
    fun countChangeReKeys() {
        // A truncated stream and an appended stream must both re-key (the count is folded in).
        assertNotEquals(fp(base), fp(base.dropLast(1)))
        assertNotEquals(fp(base), fp(base + S(ts = 1_750_000_400L, v = 7L)))
    }

    @Test
    fun emptyStreamIsStable() {
        assertEquals(fp(emptyList()), fp(emptyList()))
    }

    // ── end-to-end memo behaviour ─────────────────────────────────────────────────────────────────

    private val dev = "test"

    /** 2025-06-10 00:00:00 UTC — a fixed midnight so the night lands in the overnight band. */
    private val refMidnight = 1_749_513_600L

    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    private fun hrStream(start: Long, durationS: Int, bpm: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    /** A plain 8 h overnight still block with low HR — one detected session, non-trivial stages. */
    private fun night(): Pair<List<HrSample>, List<GravitySample>> {
        val start = refMidnight - 2 * 3_600L // 22:00 the prior evening
        val dur = 8 * 60 * 60
        return hrStream(start, dur, 50) to stillGravity(start, dur)
    }

    @Test
    fun identicalInputsTwiceReturnIdenticalSessions() {
        val (hr, grav) = night()
        val first = SleepStager.detectSleep(hr = hr, gravity = grav)
        val second = SleepStager.detectSleep(hr = hr.map { it.copy() }, gravity = grav.map { it.copy() })
        assertTrue("the synthetic night must actually detect", first.isNotEmpty())
        // Byte-identical result (data-class equality covers start/end/efficiency/stages/HR/HRV)…
        assertEquals(first, second)
        // …but NEVER shared StageSegment instances: a memo hit must hand back a fresh copy, or a caller
        // reshaping a segment in place would corrupt every later hit.
        assertNotSame(first[0].stages[0], second[0].stages[0])
    }

    @Test
    fun mutatingAReturnedResultCannotPoisonTheMemo() {
        val (hr, grav) = night()
        // Ground truth via the TRACED path, which bypasses the memo by design (the gate ladder must run
        // live in test mode) — i.e. a guaranteed-fresh compute of the same night.
        val groundTruth = SleepStager.detectSleep(hr = hr, gravity = grav, traceSink = { })
        val first = SleepStager.detectSleep(hr = hr, gravity = grav)
        assertEquals(groundTruth, first)
        // Vandalise the caller's copy in place (StageSegment is mutable — the whole hazard).
        first[0].stages[0].stage = "corrupted"
        first[0].stages[0].start += 12_345L
        // A subsequent hit must serve the pristine result, not the vandalism.
        assertEquals(groundTruth, SleepStager.detectSleep(hr = hr, gravity = grav))
    }

    @Test
    fun gravityAxesAreKeyedSeparatelyNotAsASum() {
        // Two gravity streams over the SAME timestamps whose per-sample component SUMS are identical
        // (1.0 throughout) but whose axis distribution differs completely: A is a still night on the
        // back (z=1), B flips the dominant axis every second (violent motion, no sleep). A sum-quantised
        // key (the Swift shape) would alias them — B would falsely hit A's cached sessions. The per-axis
        // fold must keep them distinct, so B computes fresh and detects nothing.
        val start = refMidnight - 2 * 3_600L
        val dur = 6 * 60 * 60
        val hr = hrStream(start, dur, 50)
        val stillA = stillGravity(start, dur)
        val flippingB = (0 until dur).map {
            if (it % 2 == 0) GravitySample(deviceId = dev, ts = start + it, x = 1.0, y = 0.0, z = 0.0)
            else GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0)
        }
        val a = SleepStager.detectSleep(hr = hr, gravity = stillA)   // caches A first
        assertTrue("the still night must detect", a.isNotEmpty())
        assertTrue("the axis-flipping stream is motion, not sleep — a non-empty result here means the " +
            "memo aliased two different gravity streams onto one key",
            SleepStager.detectSleep(hr = hr, gravity = flippingB).isEmpty())
    }

    @Test
    fun tracedAndUntracedCallsAreByteIdentical() {
        // The traceSink bypass must be observation-only: same list either way.
        val (hr, grav) = night()
        val traced = SleepStager.detectSleep(hr = hr, gravity = grav, traceSink = { })
        val untraced = SleepStager.detectSleep(hr = hr, gravity = grav)
        assertEquals(traced, untraced)
    }
}
