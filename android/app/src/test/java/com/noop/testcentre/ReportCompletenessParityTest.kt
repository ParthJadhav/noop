package com.noop.testcentre

import com.noop.analytics.ConnectionTrace
import com.noop.ble.taggedStrapLogLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parity + behaviour test for the report-completeness guard. The {domain -> killer-token} map and the
 * "Capture check" section labels MUST stay byte-identical to the Swift twin (the maintainer reads the
 * same section on every platform), so this pins the map, the section text, and the present/MISSING logic.
 */
class ReportCompletenessParityTest {

    @Test fun killerTokenMapIsTheCanonicalContract() {
        // Byte-identical to the Swift ReportCompleteness.killerTokens. UNIVERSAL plus the 9 wired domains;
        // the Phase-3 domains (notifications/sources/stress/longevity) are intentionally absent.
        assertEquals("dayOwner day=", ReportCompleteness.killerTokens[TestDomain.UNIVERSAL])
        assertEquals("gate run=", ReportCompleteness.killerTokens[TestDomain.SLEEP])
        assertEquals("clockDrift ", ReportCompleteness.killerTokens[TestDomain.CONNECTION])
        assertEquals("session event=", ReportCompleteness.killerTokens[TestDomain.WORKOUTS])
        assertEquals("dataVolume dbRows=", ReportCompleteness.killerTokens[TestDomain.DISPLAY])
        assertEquals("import parser=", ReportCompleteness.killerTokens[TestDomain.IMPORT])
        assertEquals("stepsEst ", ReportCompleteness.killerTokens[TestDomain.STEPS])
        assertEquals("battery series=", ReportCompleteness.killerTokens[TestDomain.BATTERY])
        assertEquals("charge score=", ReportCompleteness.killerTokens[TestDomain.RECOVERY])
        assertEquals("hrv rmssd=", ReportCompleteness.killerTokens[TestDomain.HRV])
        assertEquals(10, ReportCompleteness.killerTokens.size)
        // No Phase-3 token claims (we never report MISSING for a trace we never promised to emit).
        assertFalse(ReportCompleteness.killerTokens.containsKey(TestDomain.NOTIFICATIONS))
        assertFalse(ReportCompleteness.killerTokens.containsKey(TestDomain.SOURCES))
        assertFalse(ReportCompleteness.killerTokens.containsKey(TestDomain.MASTER))
    }

    @Test fun universalIsAlwaysCheckedEvenWithNoActiveMode() {
        val checked = ReportCompleteness.checkedDomains(active = emptySet())
        assertEquals(listOf(TestDomain.UNIVERSAL), checked)
    }

    @Test fun checkedDomainsKeepKillerTokenDeclarationOrder() {
        // Active set order must NOT leak into the section: it is always killerTokens declaration order so
        // the section reads identically on both platforms regardless of which modes are on.
        val active = setOf(TestDomain.HRV, TestDomain.SLEEP, TestDomain.CONNECTION)
        assertEquals(
            listOf(TestDomain.UNIVERSAL, TestDomain.SLEEP, TestDomain.CONNECTION, TestDomain.HRV),
            ReportCompleteness.checkedDomains(active),
        )
    }

    @Test fun statusesAreSubstringMatchesOverTheReport() {
        val report = buildString {
            appendLine("dayOwner day=2026-06-27 readId=my-whoop writeActiveId=my-whoop hrRows=900 provenance=measured")
            appendLine("[sleep] gate run=1 spanS=27000 KEPT gate=accepted detail=...")
            // connection NOT present -> MISSING when connection is active.
        }
        val active = setOf(TestDomain.SLEEP, TestDomain.CONNECTION)
        val s = ReportCompleteness.statuses(report, active)
        assertEquals(ReportCompleteness.Status.PRESENT, s[TestDomain.UNIVERSAL])
        assertEquals(ReportCompleteness.Status.PRESENT, s[TestDomain.SLEEP])
        assertEquals(ReportCompleteness.Status.MISSING, s[TestDomain.CONNECTION])
    }

    @Test fun captureCheckSectionExactText_complete() {
        val report = "x dayOwner day=D y\nz [sleep] gate run=1 KEPT gate=accepted w"
        val section = ReportCompleteness.captureCheckSection(report, active = setOf(TestDomain.SLEEP))
        assertEquals(
            "=== Capture check ===\n" +
                "universal: present (dayOwner day=)\n" +
                "sleep: present (gate run=)\n" +
                "complete: all active traces present",
            section,
        )
    }

    @Test fun captureCheckSectionExactText_incomplete() {
        // dayOwner present (universal informational), but the active sleep + connection traces never landed.
        val report = "header\ndayOwner day=D readId=x writeActiveId=x hrRows=0 provenance=none\nbody"
        val section = ReportCompleteness.captureCheckSection(
            report, active = setOf(TestDomain.SLEEP, TestDomain.CONNECTION),
        )
        assertEquals(
            "=== Capture check ===\n" +
                "universal: present (dayOwner day=)\n" +
                "sleep: MISSING (gate run=)\n" +
                "connection: MISSING (clockDrift )\n" +
                "INCOMPLETE: missing sleep, connection",
            section,
        )
    }

    @Test fun missingUniversalAloneIsStillComplete() {
        // The universal line is informational: its absence does NOT mark a report incomplete (a brand-new
        // install with no scored day yet has no dayOwner line, but if no domain is active that is fine).
        val section = ReportCompleteness.captureCheckSection("nothing here", active = emptySet())
        assertEquals(
            "=== Capture check ===\n" +
                "universal: MISSING (dayOwner day=)\n" +
                "complete: all active traces present",
            section,
        )
    }

    @Test fun metaTracesUseWireIdsAndCompleteFlag() {
        val report = "dayOwner day=D\nimport parser=whoopExport v=3 traceV=1"
        val meta = ReportCompleteness.captureCheckMeta(report, active = setOf(TestDomain.IMPORT))
        // IMPORT carries the wire id "import" (not "dataImport") - byte-aligned with the Swift twin.
        assertEquals("present", meta.traces["universal"])
        assertEquals("present", meta.traces["import"])
        assertTrue(meta.complete)
    }

    @Test fun metaCompleteFalseWhenActiveTraceMissing() {
        val report = "dayOwner day=D"
        val meta = ReportCompleteness.captureCheckMeta(report, active = setOf(TestDomain.BATTERY))
        assertEquals("MISSING", meta.traces["battery"])
        assertFalse(meta.complete)
    }

    @Test fun universalTaggedClockDriftSatisfiesConnectionCheck() {
        // CAPTURE-B parity invariant: the clock-drift line now rides the UNIVERSAL block (tagged .universal,
        // gated on any-mode-on), yet a Connection-active report still needs the CONNECTION killer token to
        // read PRESENT. Prove the universal-tagged line carries that exact token, so promoting clockDrift to
        // universal does NOT break the Connection completeness check. This is the cross-lane seam (the emit
        // is in WhoopBleClient; the guard is here), so we assert the two agree on the literal token.
        val line = ConnectionTrace.clockDriftLine(
            oldestUnix = 1_700_000_000L, newestUnix = 1_700_100_000L, wallNowUnix = 1_700_100_030L,
        )
        // Exactly as it lands in report.txt: redacted (no PII in this line) then tagged .universal.
        val asShipped = taggedStrapLogLine(line, TestDomain.UNIVERSAL)
        assertTrue("the universal-tagged line must carry the CONNECTION killer token",
            asShipped.contains(ReportCompleteness.killerTokens[TestDomain.CONNECTION]!!))
        // And it satisfies a Connection-active completeness check end-to-end.
        val s = ReportCompleteness.statuses(asShipped, active = setOf(TestDomain.CONNECTION))
        assertEquals(ReportCompleteness.Status.PRESENT, s[TestDomain.CONNECTION])
    }
}
