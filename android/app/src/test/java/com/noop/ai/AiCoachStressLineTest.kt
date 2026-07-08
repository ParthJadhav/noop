package com.noop.ai

import com.noop.analytics.StressIndex
import com.noop.data.RrInterval
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parity with macOS [AICoachPromptAndStressTests]: the derived Baevsky Stress Index context line.
 *
 * Covers the pure pieces (no Android Context, no IO): [AiCoach.stressIndexSummary] formats one
 * rounded number with the proxy note (no raw R-R egress), and [AiCoach.stressIndexLine] uses the
 * SAME [StressIndex.stressIndex] computation StressScreen does — reporting that value, or null when
 * there are too few clean beats so the line is simply absent.
 */
class AiCoachStressLineTest {

    /** The same 22-beat golden series StressIndexTest pins (SI ≈ 223.83 → rounds to 224). */
    private val goldenMs = listOf(
        700, 720, 740, 760, 780, 800, 820, 840, 860, 800, 800,
        800, 800, 820, 780, 800, 810, 790, 800, 800, 805, 795,
    )

    private fun rr(ms: List<Int>): List<RrInterval> =
        ms.mapIndexed { i, v -> RrInterval(deviceId = "my-whoop", ts = 1000L + i, rrMs = v) }

    @Test
    fun summaryFormatsOneRoundedNumberWithNoRawEgress() {
        val line = AiCoach.stressIndexSummary(223.82920110192836)
        assertTrue("rounds + labels: $line", line.startsWith("Stress (SI): 224 "))
        assertTrue(line.contains("Baevsky Stress Index"))
        // A single derived number only — no raw R-R reading leaks into the summary.
        assertFalse(line.contains("700"))
        assertFalse("no raw R-R values", line.contains("ms"))
    }

    @Test
    fun lineMatchesStressScreenComputation() {
        val si = StressIndex.stressIndex(rr(goldenMs))
        assertNotNull(si)
        val line = AiCoach.stressIndexLine(rr(goldenMs))
        assertNotNull(line)
        assertTrue(line!!.startsWith("Stress (SI): ${Math.round(si!!)} "))
    }

    @Test
    fun tooFewBeatsYieldsNoLine() {
        // Below StressIndex.MIN_BEATS → no SI → no line (never a fabricated number).
        val tooFew = rr(List(StressIndex.MIN_BEATS - 1) { 800 })
        assertNull(StressIndex.stressIndex(tooFew))
        assertNull(AiCoach.stressIndexLine(tooFew))
    }
}
