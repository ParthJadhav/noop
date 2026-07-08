package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Twin of the Swift TestReadoutTests: the Recovery / HRV live-readout tagged-tail parsers (Test Centre
 * Group G). Pure-JVM, no Robolectric.
 */
class TestReadoutTest {

    @Test fun lastChargeBreakdownParsesScoreAndBand() {
        val tail = listOf(
            "[recovery] charge day=2021-06-17 baseline hrv mean=50.0 spread=4.79 nValid=14 status=trusted",
            "[recovery] charge day=2021-06-17 score=62.5 band=yellow (logistic k=1.6 z0=-0.2)",
        )
        assertEquals("score=62.5 band=yellow", TestReadout.lastChargeBreakdown(tail))
    }

    @Test fun lastChargeBreakdownFallsBackToNilReason() {
        val tail = listOf(
            "[recovery] charge day=2021-06-17 nilScore reason=hrvBaselineNotUsable " +
                "hrvStatus=calibrating hrvNValid=2 (need nValid>=4)",
        )
        assertEquals("no score (hrvBaselineNotUsable)", TestReadout.lastChargeBreakdown(tail))
    }

    @Test fun lastChargeBreakdownNullWhenNoTrace() {
        assertNull(TestReadout.lastChargeBreakdown(emptyList()))
        assertNull(TestReadout.lastChargeBreakdown(listOf("[sleep] gate run=0 ... gate=accepted")))
    }

    @Test fun lastHrvComputationParsesRmssdFragment() {
        val tail = listOf(
            "[hrv] hrv path=spot nInput=60 nClean=58 rejectedFraction=0.03",
            "[hrv] hrv rmssd=42.1ms sdnn=55.3ms meanNN=812.0ms",
        )
        assertEquals("rmssd=42.1ms sdnn=55.3ms meanNN=812.0ms", TestReadout.lastHrvComputation(tail))
    }

    @Test fun lastHrvComputationReportsFilteredOut() {
        val tail = listOf("[hrv] hrv result=nil (a gate above refused the reading)")
        assertEquals("no reading (filtered out)", TestReadout.lastHrvComputation(tail))
    }
}
