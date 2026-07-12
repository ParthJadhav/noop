import XCTest
@testable import StrandImport

final class NoopHealthSleepExportTests: XCTestCase {

    // A fixed session window used across the fallback cases: 23:00 → 07:00 (8h).
    private let start = Date(timeIntervalSince1970: 1_700_000_000)          // arbitrary night onset
    private var end: Date { start.addingTimeInterval(8 * 3600) }           // +8h wake

    // MARK: - Computed segment array (real timeline)

    func testSegmentArrayDecodesEveryStageWithAbsoluteTimes() {
        let s = Int(start.timeIntervalSince1970)
        let json = """
        [
          {"start":\(s),        "end":\(s + 3600), "stage":"light"},
          {"start":\(s + 3600), "end":\(s + 5400), "stage":"deep"},
          {"start":\(s + 5400), "end":\(s + 7200), "stage":"rem"},
          {"start":\(s + 7200), "end":\(s + 7500), "stage":"wake"}
        ]
        """
        let ivs = NoopHealthSleepExport.stageIntervals(stagesJSON: json, sessionStart: start, sessionEnd: end)

        XCTAssertEqual(ivs.map(\.kind), [.core, .deep, .rem, .awake])
        // "light" maps to Apple's "core", "wake" maps to "awake".
        XCTAssertEqual(ivs[0].start, start)
        XCTAssertEqual(ivs[0].end, start.addingTimeInterval(3600))
        XCTAssertEqual(ivs[3].kind, .awake)
        // A real timeline never collapses to the whole-session fallback.
        XCTAssertFalse(ivs.contains { $0.kind == .asleepUnspecified })
    }

    func testUnknownStageAndNonPositiveSpansAreSkipped() {
        let s = Int(start.timeIntervalSince1970)
        let json = """
        [
          {"start":\(s),        "end":\(s + 1800), "stage":"deep"},
          {"start":\(s + 1800), "end":\(s + 1800), "stage":"rem"},
          {"start":\(s + 1800), "end":\(s + 3600), "stage":"unknown-stage"}
        ]
        """
        let ivs = NoopHealthSleepExport.stageIntervals(stagesJSON: json, sessionStart: start, sessionEnd: end)
        // Only the first (valid, positive-span, known-stage) segment survives.
        XCTAssertEqual(ivs.map(\.kind), [.deep])
    }

    // MARK: - Fallback to a single whole-session span

    func testImportedMinutesDictFallsBackToUnspecifiedSpan() {
        // The imported shape carries no timeline, so we can't reconstruct stages — one span instead.
        let json = #"{"light":210,"deep":75,"rem":95,"awake":20}"#
        let ivs = NoopHealthSleepExport.stageIntervals(stagesJSON: json, sessionStart: start, sessionEnd: end)
        XCTAssertEqual(ivs.count, 1)
        XCTAssertEqual(ivs.first?.kind, .asleepUnspecified)
        XCTAssertEqual(ivs.first?.start, start)
        XCTAssertEqual(ivs.first?.end, end)
    }

    func testNilAndEmptyJSONFallBackToUnspecifiedSpan() {
        for json in [nil, "", "[]", "not json"] as [String?] {
            let ivs = NoopHealthSleepExport.stageIntervals(stagesJSON: json, sessionStart: start, sessionEnd: end)
            XCTAssertEqual(ivs.count, 1, "json=\(String(describing: json))")
            XCTAssertEqual(ivs.first?.kind, .asleepUnspecified)
        }
    }

    func testDegenerateSpanWithNoSegmentsYieldsNothing() {
        // No decodable segments AND end <= start: nothing writable.
        let ivs = NoopHealthSleepExport.stageIntervals(stagesJSON: nil, sessionStart: start, sessionEnd: start)
        XCTAssertTrue(ivs.isEmpty)
    }

    func testDegenerateSpanStillHonoursARealSegmentTimeline() {
        // Even if the caller passes a collapsed [start,end], a real segment array must still export.
        let s = Int(start.timeIntervalSince1970)
        let json = #"[{"start":\#(s),"end":\#(s + 600),"stage":"rem"}]"#
        let ivs = NoopHealthSleepExport.stageIntervals(stagesJSON: json, sessionStart: start, sessionEnd: start)
        XCTAssertEqual(ivs.map(\.kind), [.rem])
    }
}
