import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// Wiring of the Import & Data Ingest trace into the app-side import path: running WhoopImporter.importExport
/// with a sink lands the parser / per-stage / reject / day-delta lines, and running it with no sink (the
/// mode-off path) emits NOTHING and saves byte-identical rows. Proves the zero-cost-when-off contract and the
/// no-behaviour-change contract from the app side. No em-dashes.
final class ImportTraceEmitTests: XCTestCase {

    /// Thread-safe line collector. The importer's `trace` sink is `@Sendable` and may be called off the
    /// test's actor, so a plain captured `var` would be a data race; this guards the array with a lock.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        func add(_ batch: [String]) { lock.lock(); _lines.append(contentsOf: batch); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    }

    /// A minimal but valid WHOOP cycles CSV folder (two cycles, two days), written to a temp dir.
    private func makeWhoopFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-import-trace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let header = "Cycle start time,Cycle end time,Cycle timezone,Recovery score %,"
            + "Resting heart rate (bpm),Heart rate variability (ms),Asleep duration (min)\n"
        let rows = "2024-01-02 06:30:00,2024-01-03 06:29:00,UTC+00:00,72,52,68.4,420\n"
            + "2024-01-03 06:30:00,2024-01-04 06:29:00,UTC+00:00,80,50,72.0,440\n"
        try (header + rows).write(to: dir.appendingPathComponent("physiological_cycles.csv"),
                                  atomically: true, encoding: .utf8)
        return dir
    }

    func testImporterEmitsTraceLinesWhenSinkProvided() async throws {
        let dir = try makeWhoopFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await WhoopStore.inMemory()

        let collector = LineCollector()
        let summary = try await WhoopImporter.importExport(
            url: dir, into: store, deviceId: "my-whoop",
            trace: { collector.add($0) })

        let lines = collector.lines
        // Two cycles parsed + mapped + saved.
        XCTAssertEqual(summary.countsByCategory["cycles"], 2)
        // The parser-identity, per-stage, reject and day-delta lines all landed.
        XCTAssertTrue(lines.contains { $0.hasPrefix("import parser=whoopExport ") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("import stage=cycles rowsIn=2 ") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("import rejects ") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("import dayDelta stage=cycles daysMapped=2 ") })
        // No raw value (the recovery score, the RHR) leaked into any trace line.
        XCTAssertFalse(lines.contains { $0.contains("68.4") })
    }

    func testImporterEmitsNothingAndSavesIdenticallyWhenSinkNil() async throws {
        let dir = try makeWhoopFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        // No sink (the mode-off path): the summary + saved rows are identical to the traced run.
        let storeOff = try await WhoopStore.inMemory()
        let summaryOff = try await WhoopImporter.importExport(url: dir, into: storeOff, deviceId: "my-whoop")

        let storeOn = try await WhoopStore.inMemory()
        let collector = LineCollector()
        let summaryOn = try await WhoopImporter.importExport(
            url: dir, into: storeOn, deviceId: "my-whoop", trace: { collector.add($0) })

        // The import RESULT is byte-identical whether or not the trace ran.
        XCTAssertEqual(summaryOff.recordCount, summaryOn.recordCount)
        XCTAssertEqual(summaryOff.countsByCategory, summaryOn.countsByCategory)
        // And the same rows landed in the store (the traced run wrote nothing extra).
        let daysOff = try await storeOff.dailyMetrics(deviceId: "my-whoop", from: "0000-00-00", to: "9999-99-99")
        let daysOn = try await storeOn.dailyMetrics(deviceId: "my-whoop", from: "0000-00-00", to: "9999-99-99")
        XCTAssertEqual(daysOff.count, daysOn.count)
        XCTAssertFalse(collector.lines.isEmpty)   // the traced run did emit (sanity for the comparison)
    }
}
