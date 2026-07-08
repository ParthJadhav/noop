import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The Workouts & GPS test mode's pure traces. Proves the auto-detect trace returns the SAME
/// [DetectedWorkout] detect(...) does (byte-identical) AND names why each window was offered or dropped,
/// plus the WorkoutsTrace line formatters and the WorkoutsReadout parser. Twin of the Android
/// AutoWorkoutDetectorTraceTest. No em-dashes.
final class AutoWorkoutDetectorTraceTests: XCTestCase {

    /// A flat 1 Hz HR block [start, start+durS) at `bpm`.
    private func block(_ start: Int, _ durS: Int, _ bpm: Int) -> [(ts: Int, bpm: Int)] {
        (0..<durS).map { (ts: start + $0, bpm: bpm) }
    }

    func testTraceResultsAreByteIdenticalToDetect() {
        let start = 1_000_000
        let durS = 20 * 60
        let hr = block(start - 600, 600, 65) + block(start, durS, 120) + block(start + durS, 600, 65)
        let plain = AutoWorkoutDetector.detect(hr: hr, restingBpm: 60)
        let (traced, lines) = AutoWorkoutDetector.detectTrace(hr: hr, restingBpm: 60)
        XCTAssertEqual(traced, plain)
        XCTAssertEqual(traced.count, 1)
        // Inputs + thresholds lines present.
        XCTAssertTrue(lines.contains { $0.hasPrefix("autoDetect path=autoDetect hrSamples=") })
        XCTAssertTrue(lines.contains { $0.contains("autoDetect thresholds elevatedMargin=30bpm") })
        XCTAssertTrue(lines.contains { $0.contains("verdict=offered") })
        XCTAssertTrue(lines.contains { $0.contains("autoDetect result windows=1") })
        XCTAssertFalse(lines.contains { $0.contains("\u{2014}") })
    }

    func testTraceNamesNoSustainedSpan() {
        // All rest, never above the floor → no span; the trace must say why.
        let hr = block(1_000_000, 1_800, 65)
        let (traced, lines) = AutoWorkoutDetector.detectTrace(hr: hr, restingBpm: 60)
        XCTAssertTrue(traced.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("why=noSustainedSpan") })
        XCTAssertTrue(lines.contains { $0.contains("result windows=0") })
    }

    func testTraceNamesSavedOverlapDrop() {
        // A real 20-min window, but a saved span covers it → detect returns [], trace says why.
        let start = 1_000_000
        let durS = 20 * 60
        let hr = block(start, durS, 120)
        let saved = [SavedWorkoutSpan(startSec: start - 60, endSec: start + durS + 60)]
        let plain = AutoWorkoutDetector.detect(hr: hr, restingBpm: 60, savedSpans: saved)
        let (traced, lines) = AutoWorkoutDetector.detectTrace(hr: hr, restingBpm: 60, savedSpans: saved)
        XCTAssertEqual(traced, plain)
        XCTAssertTrue(traced.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("verdict=dropped why=overlapsSavedWorkout") })
    }

    func testTraceNamesMotionNotConfirmed() {
        // A real HR window but a flat (no-motion) series → motion-confirm gate drops it.
        let start = 1_000_000
        let durS = 20 * 60
        let hr = block(start, durS, 120)
        let motion = (0..<durS).map { AutoWorkoutDetector.MotionPoint(ts: start + $0, intensity: 0.0) }
        let plain = AutoWorkoutDetector.detect(hr: hr, restingBpm: 60, motion: motion)
        let (traced, lines) = AutoWorkoutDetector.detectTrace(hr: hr, restingBpm: 60, motion: motion)
        XCTAssertEqual(traced, plain)
        XCTAssertTrue(traced.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("verdict=dropped why=motionNotConfirmed") })
    }

    func testWorkoutsTraceLineShapes() {
        XCTAssertEqual(
            WorkoutsTrace.sessionLine(event: "start", sportKey: "running", hrSamples: 0),
            "session event=start sport=running hrSamples=0")
        XCTAssertEqual(
            WorkoutsTrace.sessionLine(event: "end", sportKey: "running", hrSamples: 1200,
                                      durationSec: 1260, gpsPoints: 240),
            "session event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240")
        XCTAssertEqual(
            WorkoutsTrace.gpsLine(rawFixes: 250, acceptedPoints: 240, distanceM: 5012.6),
            "gps rawFixes=250 accepted=240 distanceM=5013 (filter: accuracy+speed gate)")
        XCTAssertEqual(
            WorkoutsTrace.dedupLine(sportKey: "running", keptSource: "strap", droppedSource: "apple",
                                    keptRichness: 5, droppedRichness: 1),
            "dedup sport=running kept=strap(richness=5) dropped=apple(richness=1) (same activity, richer kept)")
        // #975: the engine detected-bout decision line , persisted (no overlap) and dropped (overlaps a real).
        XCTAssertEqual(
            WorkoutsTrace.detectedBoutLine(verdict: "persisted", durMin: 42, avgBpm: 148),
            "detectedBout verdict=persisted durMin=42 avgBpm=148")
        XCTAssertEqual(
            WorkoutsTrace.detectedBoutLine(verdict: "droppedOverlap", durMin: 42, avgBpm: 148,
                                                 overlapSource: "manual"),
            "detectedBout verdict=droppedOverlap durMin=42 avgBpm=148 overlapSource=manual")
    }

    func testWorkoutsReadoutParsesLastSession() {
        let tail = [
            "[workouts] session event=start sport=running hrSamples=0",
            "[workouts] session event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240",
        ]
        XCTAssertEqual(WorkoutsReadout.lastSessionSummary(taggedTail: tail),
                       "event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240")
        XCTAssertNil(WorkoutsReadout.lastSessionSummary(taggedTail: []))
    }
}
