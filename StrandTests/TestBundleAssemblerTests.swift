import XCTest
@testable import Strand

final class TestBundleAssemblerTests: XCTestCase {

    func testReScrubsEveryFileIncludingRawCapture() {
        // A serial that never went through the append(log:) sink, e.g. embedded in raw-capture console text.
        let rawWithSerial = "{\"console\":\"connected to WHOOP 4C1594026 ok\"}"
        let entries = [
            FileExport.BundleEntry(name: "report.txt", data: Data("clean line".utf8)),
            FileExport.BundleEntry(name: "raw-capture.jsonl", data: Data(rawWithSerial.utf8)),
        ]
        let scrubbed = TestBundleAssembler.redactEntries(entries)
        let raw = scrubbed.first { $0.name == "raw-capture.jsonl" }!
        let text = String(data: raw.data, encoding: .utf8)!
        XCTAssertFalse(text.contains("4C1594026"), "the injected serial must be scrubbed")
        XCTAssertTrue(text.contains("WHOOP <serial>"))
    }

    func testMetaJsonIsNotMangledButStillPasses() {
        // meta.json has no PII shapes, so it should pass through byte-identical.
        let json = Data("{\"schema\":1,\"redaction\":\"v2\"}".utf8)
        let scrubbed = TestBundleAssembler.redactEntries([FileExport.BundleEntry(name: "meta.json", data: json)])
        XCTAssertEqual(scrubbed.first!.data, json)
    }

    func testStampsRedactionV2() {
        XCTAssertEqual(TestBundleAssembler.redactionVersion, "v2")
    }

    func testCapTruncatesRawCaptureTailAndFlags() {
        // report.txt + meta.json are small; raw-capture blows the cap. We keep the most-recent tail.
        let small = FileExport.BundleEntry(name: "report.txt", data: Data("small".utf8))
        let oversized = String(repeating: "x", count: 40 * 1024 * 1024)  // 40 MB of raw-capture
        let entries = [small, FileExport.BundleEntry(name: "raw-capture.jsonl", data: Data(oversized.utf8))]

        let (capped, truncated) = TestBundleAssembler.capEntries(entries, capBytes: 20 * 1024 * 1024)
        XCTAssertTrue(truncated, "the bundle exceeded the cap so truncated must be true")
        let total = capped.reduce(0) { $0 + $1.data.count }
        XCTAssertLessThanOrEqual(total, 20 * 1024 * 1024)
        // report.txt is preserved in full; only raw-capture is trimmed.
        XCTAssertEqual(capped.first { $0.name == "report.txt" }?.data, small.data)
        let raw = capped.first { $0.name == "raw-capture.jsonl" }!
        XCTAssertLessThan(raw.data.count, oversized.utf8.count)
        // We keep the TAIL (most recent), so the last byte survives.
        XCTAssertEqual(raw.data.last, Data(oversized.utf8).last)
    }

    func testCapLeavesUndersizedBundleUntouched() {
        let entries = [FileExport.BundleEntry(name: "report.txt", data: Data("tiny".utf8))]
        let (capped, truncated) = TestBundleAssembler.capEntries(entries, capBytes: 20 * 1024 * 1024)
        XCTAssertFalse(truncated)
        XCTAssertEqual(capped, entries)
    }
}
