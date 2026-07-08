package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * CAPTURE-B parity: pins the verbatim universal `dayOwner …` line the Android IntelligenceEngine emits so
 * EVERY Test Centre export self-diagnoses the read-vs-write identity (the #814/#799 spine bug) and each
 * day's data provenance. The format is byte-identical to the iOS lanes' shared contract:
 *
 *   dayOwner day=<localDayKey> readId=<owner> writeActiveId=<registryActiveId> hrRows=<N> provenance=<...>
 *
 * provenance ∈ {measured, imported:whoop, imported:apple, none}. Pure + set-based; the SAME helpers
 * analyzeRecent ships, so the two platforms log identical lines.
 */
class IntelligenceDayOwnerLineTest {

    private val day = "2026-06-12"

    // MARK: provenance token

    @Test fun provenance_noneWhenNoHrAndNoImport() {
        assertEquals("none",
            IntelligenceEngine.universalProvenanceToken(day, hrRows = 0, emptySet(), emptySet()))
    }

    @Test fun provenance_measuredWhenHrButNoImport() {
        assertEquals("measured",
            IntelligenceEngine.universalProvenanceToken(day, hrRows = 1234, emptySet(), emptySet()))
    }

    @Test fun provenance_importedWhoopWinsEvenWithHr() {
        // A WHOOP export covering the day wins the dashboard merge, so it is named even when HR was also
        // read that day (the merge precedence the universal line reports).
        assertEquals("imported:whoop",
            IntelligenceEngine.universalProvenanceToken(day, hrRows = 5000, setOf(day), emptySet()))
    }

    @Test fun provenance_importedAppleWhenOnlyAppleCovers() {
        assertEquals("imported:apple",
            IntelligenceEngine.universalProvenanceToken(day, hrRows = 0, emptySet(), setOf(day)))
    }

    @Test fun provenance_whoopBeatsApple() {
        assertEquals("imported:whoop",
            IntelligenceEngine.universalProvenanceToken(day, hrRows = 0, setOf(day), setOf(day)))
    }

    @Test fun provenance_perDayNotGlobal() {
        val imported = setOf("2026-06-10")
        // An import on a DIFFERENT day must not relabel this day; a day with HR reads measured, not whoop.
        assertEquals("measured",
            IntelligenceEngine.universalProvenanceToken("2026-06-12", hrRows = 900, imported, emptySet()))
        assertEquals("imported:whoop",
            IntelligenceEngine.universalProvenanceToken("2026-06-10", hrRows = 900, imported, emptySet()))
    }

    // MARK: the verbatim line

    @Test fun line_isByteIdenticalToTheContract() {
        val line = IntelligenceEngine.dayOwnerLine(
            day = day,
            readId = "my-whoop",
            writeActiveId = "my-whoop",
            hrRows = 8421,
            importedWhoopDays = emptySet(),
            appleHealthDays = emptySet(),
        )
        assertEquals(
            "dayOwner day=2026-06-12 readId=my-whoop writeActiveId=my-whoop hrRows=8421 provenance=measured",
            line,
        )
        assertFalse(line.contains("\u2014")) // no em-dash in the diagnostic line
    }

    @Test fun line_surfacesReadWriteMismatch() {
        // The spine symptom: the read owner and the active write id diverge. The line names BOTH so a
        // shared export shows it instead of hiding it.
        val line = IntelligenceEngine.dayOwnerLine(
            day = day,
            readId = "my-whoop",            // read still pinned to the old strap
            writeActiveId = "polar-h10",    // but new data writes under the active band
            hrRows = 0,
            importedWhoopDays = emptySet(),
            appleHealthDays = emptySet(),
        )
        assertTrue(line.contains("readId=my-whoop"))
        assertTrue(line.contains("writeActiveId=polar-h10"))
        assertTrue(line.contains("provenance=none")) // no HR that day under the read owner
    }

    @Test fun line_namesImportProvenance() {
        val line = IntelligenceEngine.dayOwnerLine(
            day = day,
            readId = "my-whoop",
            writeActiveId = "my-whoop",
            hrRows = 3000,
            importedWhoopDays = setOf(day),
            appleHealthDays = emptySet(),
        )
        assertTrue(line.endsWith("provenance=imported:whoop"))
    }
}
