package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behaviour + parity test for the bundle robustness check. Verifies the last-line verdict over the final
 * shipping bytes: required files present, attachments honoured when expected, and - the #453 / 5.3 net -
 * that no raw MAC / serial survived redaction. The summary line shape is byte-aligned with the Swift twin.
 */
class BundleRobustnessTest {

    private val pngBytes = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    @Test fun wellFormedBundleIsOk() {
        val entries = listOf(
            "report.txt" to "clean diagnostic line".toByteArray(),
            "meta.json" to "{}".toByteArray(),
        )
        val r = BundleRobustness.verify(entries, expectScreenshot = false, crashWasCaptured = false)
        assertTrue(r.ok)
        assertTrue(r.hasReport)
        assertTrue(r.reportNonEmpty)
        assertTrue(r.hasMeta)
        assertTrue(r.leakingEntries.isEmpty())
    }

    @Test fun missingReportFails() {
        val entries = listOf("meta.json" to "{}".toByteArray())
        val r = BundleRobustness.verify(entries, expectScreenshot = false, crashWasCaptured = false)
        assertFalse(r.ok)
        assertFalse(r.hasReport)
    }

    @Test fun emptyReportFails() {
        val entries = listOf(
            "report.txt" to ByteArray(0),
            "meta.json" to "{}".toByteArray(),
        )
        val r = BundleRobustness.verify(entries, expectScreenshot = false, crashWasCaptured = false)
        assertFalse(r.ok)
        assertFalse(r.reportNonEmpty)
    }

    @Test fun expectedScreenshotMissingFails() {
        val entries = listOf(
            "report.txt" to "x".toByteArray(),
            "meta.json" to "{}".toByteArray(),
        )
        val r = BundleRobustness.verify(entries, expectScreenshot = true, crashWasCaptured = false)
        assertFalse(r.ok)
        assertFalse(r.screenshotExpectedAndPresent)
    }

    @Test fun expectedScreenshotPresentPasses() {
        val entries = listOf(
            "report.txt" to "x".toByteArray(),
            "meta.json" to "{}".toByteArray(),
            DisplayScreenshot.BUNDLE_NAME to pngBytes,
        )
        val r = BundleRobustness.verify(entries, expectScreenshot = true, crashWasCaptured = false)
        assertTrue(r.ok)
        assertTrue(r.screenshotExpectedAndPresent)
    }

    @Test fun capturedCrashMustBeAttached() {
        val withoutCrash = listOf(
            "report.txt" to "x".toByteArray(),
            "meta.json" to "{}".toByteArray(),
        )
        val r1 = BundleRobustness.verify(withoutCrash, expectScreenshot = false, crashWasCaptured = true)
        assertFalse("a captured crash that is not attached is a failure", r1.ok)
        assertFalse(r1.crashAttachedWhenCaptured)

        val withCrash = withoutCrash + ("last-crash.txt" to "stack...".toByteArray())
        val r2 = BundleRobustness.verify(withCrash, expectScreenshot = false, crashWasCaptured = true)
        assertTrue(r2.ok)
        assertTrue(r2.crashAttachedWhenCaptured)
    }

    @Test fun noCrashCapturedDoesNotRequireAttachment() {
        val entries = listOf(
            "report.txt" to "x".toByteArray(),
            "meta.json" to "{}".toByteArray(),
        )
        val r = BundleRobustness.verify(entries, expectScreenshot = false, crashWasCaptured = false)
        assertTrue(r.ok)
        assertTrue("absent crash when none captured is correct", r.crashAttachedWhenCaptured)
    }

    @Test fun rawMacLeakInAnyTextEntryFails() {
        // An UNMASKED MAC (all six octets) must never survive redaction. The redacted form has "••" in the
        // middle four octets and would NOT match, so this catches a genuine redaction regression.
        val entries = listOf(
            "report.txt" to "x".toByteArray(),
            "meta.json" to "{}".toByteArray(),
            "raw-capture.jsonl" to "{\"mac\":\"AA:BB:CC:DD:EE:FF\"}".toByteArray(),
        )
        val r = BundleRobustness.verify(entries, expectScreenshot = false, crashWasCaptured = false)
        assertFalse(r.ok)
        assertEquals(listOf("raw-capture.jsonl"), r.leakingEntries)
    }

    @Test fun rawSerialLeakFails() {
        val entries = listOf(
            "report.txt" to "connected to WHOOP 4C1594026 ok".toByteArray(),
            "meta.json" to "{}".toByteArray(),
        )
        val r = BundleRobustness.verify(entries, expectScreenshot = false, crashWasCaptured = false)
        assertFalse(r.ok)
        assertEquals(listOf("report.txt"), r.leakingEntries)
    }

    @Test fun redactedFormsDoNotFalsePositive() {
        // The masked MAC and the "WHOOP <serial>" placeholder are the EXPECTED redacted output - they must
        // not trip the leak scan, or every healthy bundle would fail.
        val entries = listOf(
            "report.txt" to "mac=AA:••:••:••:••:FF dev=WHOOP <serial> connected".toByteArray(),
            "meta.json" to "{}".toByteArray(),
        )
        val r = BundleRobustness.verify(entries, expectScreenshot = false, crashWasCaptured = false)
        assertTrue(r.ok)
        assertTrue(r.leakingEntries.isEmpty())
    }

    @Test fun screenshotBytesAreNotScannedForPii() {
        // The binary PNG is excluded from the text/PII scan: arbitrary image bytes could coincidentally match
        // a MAC/serial pattern, which is not a leak. Mirrors the assembler's binary-entry handling.
        val entries = listOf(
            "report.txt" to "clean".toByteArray(),
            "meta.json" to "{}".toByteArray(),
            DisplayScreenshot.BUNDLE_NAME to "AA:BB:CC:DD:EE:FF".toByteArray(),  // bytes that LOOK like a MAC
        )
        val r = BundleRobustness.verify(entries, expectScreenshot = true, crashWasCaptured = false)
        assertTrue(r.ok)
        assertTrue(r.leakingEntries.isEmpty())
    }

    @Test fun summaryLineShapeIsByteAlignedWithSwift() {
        val entries = listOf(
            "report.txt" to "clean".toByteArray(),
            "meta.json" to "{}".toByteArray(),
        )
        val r = BundleRobustness.verify(entries, expectScreenshot = false, crashWasCaptured = false)
        assertEquals(
            "bundle ok files=2 report=present meta=present screenshot=present crash=present leaks=0",
            r.summaryLine(entries.size),
        )
    }

    @Test fun summaryLineFailShape() {
        val entries = listOf("meta.json" to "{}".toByteArray())  // no report.txt
        val r = BundleRobustness.verify(entries, expectScreenshot = true, crashWasCaptured = false)
        assertEquals(
            "bundle FAIL files=1 report=MISSING meta=present screenshot=MISSING crash=present leaks=0",
            r.summaryLine(entries.size),
        )
    }
}
