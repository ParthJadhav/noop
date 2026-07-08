package com.noop.testcentre

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Report flow must not share an uncleared bundle (spec section 12). */
class TestReportFlowGatedTest {

    private fun entries() = listOf("report.txt" to "x".toByteArray())

    @Test
    fun unclearedGateBlocksProceed() {
        assertFalse(TestReportFlow.shouldProceed(ReportReviewGate(entries())))
    }

    @Test
    fun clearedGateAllowsProceed() {
        val gate = ReportReviewGate(entries())
        gate.confirm()
        assertTrue(TestReportFlow.shouldProceed(gate))
    }
}
