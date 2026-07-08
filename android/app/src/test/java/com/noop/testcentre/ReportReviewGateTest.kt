package com.noop.testcentre

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Twin of the Swift ReportReviewGateTests: the mandatory, non-skippable review gate (spec sections
 * 9, 12). A fresh or cancelled gate never clears; only an explicit confirm clears; the preview shows
 * the report.txt the user is about to share.
 */
class ReportReviewGateTest {

    private fun sampleEntries(): List<Pair<String, ByteArray>> =
        listOf("report.txt" to "NOOP strap log\nline 1\nline 2".toByteArray())

    @Test
    fun freshGateIsNotCleared() {
        assertFalse(ReportReviewGate(sampleEntries()).isCleared)
    }

    @Test
    fun previewShowsTheReportText() {
        val gate = ReportReviewGate(sampleEntries())
        assertTrue(gate.previewText.contains("line 1"))
        assertTrue(gate.previewText.contains("line 2"))
    }

    @Test
    fun confirmClearsAndCancelDoesNot() {
        val gate = ReportReviewGate(sampleEntries())
        gate.cancel()
        assertFalse(gate.isCleared)
        gate.confirm()
        assertTrue(gate.isCleared)
    }
}
