import XCTest
@testable import StrandImport

/// Pins the Import & Data Ingest test-mode line shapes (ImportTrace) and the readout parser (ImportReadout),
/// plus the PRIVACY floor: a failing row / file sample is masked (digits -> #, letters -> x, structure kept)
/// and length-capped before it can ever reach the log line. The Kotlin twin (ImportTraceTest.kt) pins the
/// same shapes so a shared report reads identically on either platform. No em-dashes.
final class ImportTraceTests: XCTestCase {

    // MARK: - parserVersion + fileMeta

    func testParserVersionLine() {
        XCTAssertEqual(
            ImportTrace.parserVersionLine(sourceKind: .whoopExport, importerVersion: 1),
            "import parser=whoopExport v=1 traceV=\(ImportTrace.traceVersion)")
    }

    func testFileMetaLineBucketsSizeAndSanitisesExt() {
        XCTAssertEqual(
            ImportTrace.fileMetaLine(sourceKind: .appleHealth, ext: "ZIP", sizeBytes: 5_000_000),
            "import file kind=appleHealth ext=zip size=1-10MB")
        // A weird extension is reduced to alphanumerics and capped; a missing one reads "none".
        XCTAssertEqual(ImportTrace.safeExt(".cs v!"), "csv")
        XCTAssertEqual(ImportTrace.safeExt(""), "none")
    }

    // MARK: - perStageRows / rejectCounts / dayDeltas

    func testStageLineNotesUnwrittenGap() {
        XCTAssertEqual(ImportTrace.stageLine(category: "cycles", rowsIn: 30, rowsOut: 30),
                       "import stage=cycles rowsIn=30 rowsOut=30 (all written)")
        XCTAssertEqual(ImportTrace.stageLine(category: "cycles", rowsIn: 30, rowsOut: 28),
                       "import stage=cycles rowsIn=30 rowsOut=28 (2 not written)")
    }

    func testRejectLine() {
        XCTAssertEqual(ImportTrace.rejectLine(droppedRows: 3, skippedSpans: 1),
                       "import rejects droppedRows=3 skippedSpans=1")
    }

    func testDayDeltaLineNotesUnpersistedGap() {
        XCTAssertEqual(ImportTrace.dayDeltaLine(category: "cycles", daysMapped: 30, daysPersisted: 30),
                       "import dayDelta stage=cycles daysMapped=30 daysPersisted=30 (all days persisted)")
        XCTAssertEqual(ImportTrace.dayDeltaLine(category: "cycles", daysMapped: 30, daysPersisted: 27),
                       "import dayDelta stage=cycles daysMapped=30 daysPersisted=27 (3 days not persisted)")
    }

    // MARK: - firstFailingRow + failingFileSample REDACTION (privacy floor)

    func testFirstFailingRowMasksEveryCellValue() {
        let line = ImportTrace.firstFailingRowLine(
            category: "cycles", rowIndex: 7,
            headerKeys: ["cycle_start_time", "recovery_score_pct"],
            rawCells: ["2024-06-01 23:30:00", "73.5"])
        // The header keys (schema, not data) survive; the cell VALUES are masked digit->#, letter->x, with
        // punctuation kept so the shape is still readable. No real timestamp or score appears.
        XCTAssertEqual(line,
            "import firstFailingRow stage=cycles row=7 "
            + "cols=[cycle_start_time,recovery_score_pct] masked=[####-##-## ##:##:##,##.#]")
        // Sanity: not a single original digit/letter from the values leaked.
        XCTAssertFalse(line!.contains("2024"))
        XCTAssertFalse(line!.contains("73"))
    }

    func testFirstFailingRowNilWhenNoCells() {
        XCTAssertNil(ImportTrace.firstFailingRowLine(
            category: "cycles", rowIndex: 1, headerKeys: ["a"], rawCells: []))
    }

    func testFailingFileSampleMasksAndCaps() {
        let raw = "Heart rate variability (ms),Recovery score %\n62,88\n"
        let lines = ImportTrace.failingFileSampleLines(sourceKind: .ouraImport, rawSample: raw)
        XCTAssertEqual(lines.count, 1)
        let s = lines[0]
        // The structure (the comma delimiter, the parens) survives; every letter/digit is masked.
        XCTAssertTrue(s.hasPrefix("import failingFileSample kind=ouraImport "))
        XCTAssertTrue(s.contains("sample=["))
        XCTAssertFalse(s.contains("Heart"))
        XCTAssertFalse(s.contains("62"))
        XCTAssertFalse(s.contains("88"))
    }

    func testRedactSampleCapsLength() {
        let long = String(repeating: "a1,", count: 500)   // 1500 chars before masking
        let masked = ImportTrace.redactSample(long)
        XCTAssertLessThanOrEqual(masked.count, ImportTrace.maxSampleChars + 3)   // + the "..." marker
        XCTAssertTrue(masked.hasSuffix("..."))
    }

    func testRedactCellKeepsStructureDropsValue() {
        XCTAssertEqual(ImportTrace.redactCell("Abc 12.3-X"), "xxx ##.#-x")
        XCTAssertEqual(ImportTrace.redactCell(""), "")
    }

    // MARK: - ImportReadout

    func testLastImportSummaryParsesTaggedTail() {
        // The tail the live sink would hold for one import run (the "[import] " tag is stripped by
        // taggedTail before it reaches the readout, so these are the bodies).
        let tail = [
            "import file kind=whoopExport ext=zip size=1-10MB",
            "import parser=whoopExport v=1 traceV=1",
            "import stage=cycles rowsIn=30 rowsOut=28 (2 not written)",
            "import stage=sleeps rowsIn=31 rowsOut=31 (all written)",
            "import dayDelta stage=cycles daysMapped=30 daysPersisted=28 (2 days not persisted)",
        ]
        let s = ImportReadout.lastImportSummary(taggedTail: tail)
        XCTAssertEqual(s,
            "parser=whoopExport v=1 traceV=1 "
            + "· stage=sleeps rowsIn=31 rowsOut=31 (all written) "
            + "· stage=cycles daysMapped=30 daysPersisted=28 (2 days not persisted)")
    }

    func testLastImportSummaryNilWhenNoImportTraced() {
        XCTAssertNil(ImportReadout.lastImportSummary(taggedTail: ["gate run kept", "connect up"]))
    }
}
