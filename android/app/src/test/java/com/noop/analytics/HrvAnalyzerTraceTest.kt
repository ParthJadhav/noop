package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Twin of the Swift HRVAnalyzerTraceTests: the HRV & Autonomic test mode's pure cleaning trace. Proves
 * the trace's returned HrvResult equals HrvAnalyzer.analyzeRaw exactly (byte-identical), and the count /
 * gate lines. No em-dashes. Pure-JVM, no Robolectric.
 */
class HrvAnalyzerTraceTest {

    @Test fun traceResultIsByteIdenticalToAnalyze() {
        val nn = listOf(
            800.0, 810.0, 805.0, 815.0, 800.0, 820.0, 810.0, 800.0, 815.0, 805.0, 810.0,
            800.0, 820.0, 815.0, 805.0, 810.0, 800.0, 815.0, 810.0, 805.0, 800.0, 820.0,
        )
        val plain = HrvAnalyzer.analyzeRaw(nn)
        val (traced, lines) = HrvAnalyzerTrace.analyzeTrace(nn)
        assertEquals(plain, traced)
        assertTrue(lines.any { it.contains("nInput=22") && it.contains("nClean=22") })
        assertTrue(lines.any { it.contains("minBeats need=20") && it.contains("CLEARED") })
        assertTrue(lines.any { it.startsWith("hrv rmssd=") })
        assertFalse(lines.any { it.contains("\u2014") })
    }

    @Test fun traceReportsMinBeatsFailureAndNilResult() {
        val rr = List(19) { 800.0 }
        val plain = HrvAnalyzer.analyzeRaw(rr)
        val (traced, lines) = HrvAnalyzerTrace.analyzeTrace(rr)
        assertEquals(plain, traced)
        assertNull(traced.rmssd)
        assertTrue(lines.any { it.contains("minBeats need=20 clean=19 FAILED") })
        assertTrue(lines.any { it.contains("result=nil") })
    }

    @Test fun traceReportsRangeAndEctopicRejection() {
        // 21 near 800 + one 250 ms (out of range) + one wild 1600 ms (ectopic vs ~800 median).
        val rr = ArrayList<Double>()
        rr.add(250.0)                 // out of range (< RR_MIN_MS)
        rr.addAll(List(5) { 800.0 })
        rr.add(1600.0)                // in range but >20% off the local median → ectopic
        rr.addAll(List(16) { 800.0 })
        val (traced, lines) = HrvAnalyzerTrace.analyzeTrace(rr)
        assertEquals(HrvAnalyzer.analyzeRaw(rr), traced)
        val rejectLine = lines.first { it.startsWith("hrv reject ") }
        assertTrue(rejectLine.contains("range=1"))
        assertTrue(rejectLine.contains("ectopic=1"))
    }

    @Test fun spotGateLineOnlyWhenCeilingSupplied() {
        val nn = List(22) { 800.0 }
        val (_, contLines) = HrvAnalyzerTrace.analyzeTrace(nn, maxRejectedFraction = null, path = "continuous")
        assertFalse(contLines.any { it.contains("spotGate") })
        assertTrue(contLines.any { it.contains("path=continuous") })
        val (_, spotLines) = HrvAnalyzerTrace.analyzeTrace(
            nn, HrvAnalyzer.DEFAULT_SPOT_MAX_REJECTED_FRACTION, path = "spot",
        )
        assertTrue(spotLines.any { it.contains("spotGate") && it.contains("PASS") })
    }
}
