package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Import & Data Ingest line formatters + readout parser (Test Centre). Pure JVM - no Robolectric, no
 * Mockito/MockK - so fixtures pin the exact line shapes the Kotlin and Swift emitters share, AND the privacy
 * floor (a failing row / file sample is masked + capped before it can reach the log line). Twin of the
 * Swift ImportTraceTests. No em-dashes.
 */
class ImportTraceTest {

    @Test fun parserVersionLine() {
        assertEquals(
            "import parser=whoopExport v=1 traceV=${ImportTrace.TRACE_VERSION}",
            ImportTrace.parserVersionLine("whoopExport", importerVersion = 1),
        )
    }

    @Test fun fileMetaLineBucketsSizeAndSanitisesExt() {
        assertEquals(
            "import file kind=appleHealth ext=zip size=1-10MB",
            ImportTrace.fileMetaLine("appleHealth", ext = "ZIP", sizeBytes = 5_000_000L),
        )
        assertEquals("csv", ImportTrace.safeExt(".cs v!"))
        assertEquals("none", ImportTrace.safeExt(""))
    }

    @Test fun stageLineNotesUnwrittenGap() {
        assertEquals(
            "import stage=cycles rowsIn=30 rowsOut=30 (all written)",
            ImportTrace.stageLine("cycles", rowsIn = 30, rowsOut = 30),
        )
        assertEquals(
            "import stage=cycles rowsIn=30 rowsOut=28 (2 not written)",
            ImportTrace.stageLine("cycles", rowsIn = 30, rowsOut = 28),
        )
    }

    @Test fun rejectLine() {
        assertEquals(
            "import rejects droppedRows=3 skippedSpans=1",
            ImportTrace.rejectLine(droppedRows = 3, skippedSpans = 1),
        )
    }

    @Test fun stageLineUnverifiedNeverClaimsWritten() {
        // The Android seam has no Room store-write count, so the line must mark rowsOut UNVERIFIED rather
        // than claim "(all written)" - the honesty fix for the #601/#749/#754 "didn't save" cluster.
        val line = ImportTrace.stageLineUnverified("cycles", rowsIn = 30)
        assertEquals(
            "import stage=cycles rowsIn=30 rowsOut=? (store-write not verified on Android)",
            line,
        )
        assertFalse(line.contains("(all written)"))
    }

    @Test fun dayDeltaLineUnverifiedNeverClaimsPersisted() {
        val line = ImportTrace.dayDeltaLineUnverified("appleDaily", daysMapped = 14)
        assertEquals(
            "import dayDelta stage=appleDaily daysMapped=14 daysPersisted=? (store-write not verified on Android)",
            line,
        )
        assertFalse(line.contains("(all days persisted)"))
    }

    // M1 parity: the Android raw Room-table count keys map to the SAME Swift import-trace category vocabulary
    // (WhoopImporter.swift: cycles/sleeps/workouts; AppleHealthImport.swift: appleDaily/dailyMetric/workouts),
    // so a cross-platform report keys every stage= line off identical names.
    @Test fun categoryWireMapsWhoopTableKeysToSwiftCategories() {
        assertEquals("cycles", ImportTrace.categoryWire("WHOOP", "dailyMetric"))
        assertEquals("sleeps", ImportTrace.categoryWire("WHOOP", "sleepSession"))
        assertEquals("workouts", ImportTrace.categoryWire("WHOOP", "workout"))
        // No Swift category for these: keep the raw key (still a stable, non-free-text id).
        assertEquals("journal", ImportTrace.categoryWire("WHOOP", "journal"))
        assertEquals("metricSeries", ImportTrace.categoryWire("WHOOP", "metricSeries"))
    }

    @Test fun categoryWireMapsAppleTableKeysToSwiftCategories() {
        // Apple keeps its own appleDaily/dailyMetric split (already matches Swift); only workout -> workouts.
        assertEquals("appleDaily", ImportTrace.categoryWire("Apple Health", "appleDaily"))
        assertEquals("dailyMetric", ImportTrace.categoryWire("Apple Health", "dailyMetric"))
        assertEquals("workouts", ImportTrace.categoryWire("Apple Health", "workout"))
        assertEquals("metricSeries", ImportTrace.categoryWire("Apple Health", "metricSeries"))
    }

    @Test fun dayDeltaLineNotesUnpersistedGap() {
        assertEquals(
            "import dayDelta stage=cycles daysMapped=30 daysPersisted=30 (all days persisted)",
            ImportTrace.dayDeltaLine("cycles", daysMapped = 30, daysPersisted = 30),
        )
        assertEquals(
            "import dayDelta stage=cycles daysMapped=30 daysPersisted=27 (3 days not persisted)",
            ImportTrace.dayDeltaLine("cycles", daysMapped = 30, daysPersisted = 27),
        )
    }

    @Test fun firstFailingRowMasksEveryCellValue() {
        val line = ImportTrace.firstFailingRowLine(
            category = "cycles", rowIndex = 7,
            headerKeys = listOf("cycle_start_time", "recovery_score_pct"),
            rawCells = listOf("2024-06-01 23:30:00", "73.5"),
        )
        assertEquals(
            "import firstFailingRow stage=cycles row=7 " +
                "cols=[cycle_start_time,recovery_score_pct] masked=[####-##-## ##:##:##,##.#]",
            line,
        )
        assertFalse(line!!.contains("2024"))
        assertFalse(line.contains("73"))
    }

    @Test fun firstFailingRowNullWhenNoCells() {
        assertNull(
            ImportTrace.firstFailingRowLine("cycles", 1, listOf("a"), emptyList()),
        )
    }

    @Test fun failingFileSampleMasksAndCaps() {
        val raw = "Heart rate variability (ms),Recovery score %\n62,88\n"
        val lines = ImportTrace.failingFileSampleLines("ouraImport", raw)
        assertEquals(1, lines.size)
        val s = lines[0]
        assertTrue(s, s.startsWith("import failingFileSample kind=ouraImport "))
        assertTrue(s, s.contains("sample=["))
        assertFalse(s, s.contains("Heart"))
        assertFalse(s, s.contains("62"))
        assertFalse(s, s.contains("88"))
    }

    @Test fun redactSampleCapsLength() {
        val long = "a1,".repeat(500)
        val masked = ImportTrace.redactSample(long)
        assertTrue(masked.length <= ImportTrace.MAX_SAMPLE_CHARS + 3)
        assertTrue(masked.endsWith("..."))
    }

    @Test fun redactCellKeepsStructureDropsValue() {
        assertEquals("xxx ##.#-x", ImportTrace.redactCell("Abc 12.3-X"))
        assertEquals("", ImportTrace.redactCell(""))
    }

    @Test fun redactCellMasksWholeUnicodeNumberGroupLikeSwift() {
        // Swift's Character.isNumber masks the WHOLE Unicode Number group, not just decimal digits. A
        // superscript two (U+00B2, category No) and a Roman numeral (U+2160, category Nl) must mask to "#"
        // so the Kotlin output is byte-identical to the Swift twin - Kotlin's isDigit() would have left both.
        assertEquals("#", ImportTrace.redactCell("²"))
        assertEquals("#", ImportTrace.redactCell("Ⅰ"))
    }

    @Test fun kindWireMapsKnownLabels() {
        assertEquals("whoopExport", ImportTrace.kindWire("WHOOP"))
        assertEquals("appleHealth", ImportTrace.kindWire("Apple Health"))
        assertEquals("xiaomiBand", ImportTrace.kindWire("Xiaomi Smart Band"))
    }

    @Test fun lastImportSummaryParsesTaggedTail() {
        val tail = listOf(
            "import file kind=whoopExport ext=zip size=1-10MB",
            "import parser=whoopExport v=1 traceV=1",
            "import stage=cycles rowsIn=30 rowsOut=28 (2 not written)",
            "import stage=sleeps rowsIn=31 rowsOut=31 (all written)",
            "import dayDelta stage=cycles daysMapped=30 daysPersisted=28 (2 days not persisted)",
        )
        assertEquals(
            "parser=whoopExport v=1 traceV=1 " +
                "· stage=sleeps rowsIn=31 rowsOut=31 (all written) " +
                "· stage=cycles daysMapped=30 daysPersisted=28 (2 days not persisted)",
            ImportReadout.lastImportSummary(tail),
        )
    }

    @Test fun lastImportSummaryNullWhenNoImportTraced() {
        assertNull(ImportReadout.lastImportSummary(listOf("gate run kept", "connect up")))
    }
}
