import XCTest
import Foundation
import WhoopProtocol
@testable import Strand

/// #833 (on-open freeze): the per-workout HR reduction (mean bpm → rounded Int + peak bpm) was pulled OUT of
/// the @MainActor `reconcileWorkoutHrWithTrace` loop, where it summed/maxed up to 8000 ints on the actor that
/// drives SwiftUI for every reconciled row (the beach-ball). It now lives in the `nonisolated static`
/// `Repository.reduceWorkoutHr`, run inside the reconcile's `withTaskGroup` child tasks OFF the main actor.
/// These tests pin its arithmetic (byte-identical to the old inline `reduce(0,+)` / `max()`) AND that it
/// genuinely runs off the main actor.
final class WorkoutHrReduceTests: XCTestCase {

    private func samples(_ bpms: [Int]) -> [HRSample] {
        bpms.enumerated().map { HRSample(ts: 1_780_000_000 + $0.offset, bpm: $0.element) }
    }

    /// Mean is the rounded average of the bpm column; peak is the true maximum. Same result the old inline
    /// `Int((Double(bpms.reduce(0,+)) / Double(bpms.count)).rounded())` + `bpms.max()` produced.
    func testReduceComputesRoundedMeanAndPeak() {
        let (avg, peak) = Repository.reduceWorkoutHr(samples([60, 61, 62, 63]))
        XCTAssertEqual(avg, 62)   // 246 / 4 = 61.5 → rounds to 62
        XCTAssertEqual(peak, 63)
    }

    /// Rounding follows `.rounded()` (round-half-to-even-free: 0.5 rounds away from zero), matching the
    /// original. 120 + 121 = 241 / 2 = 120.5 → 121.
    func testReduceMeanRoundsHalfUp() {
        let (avg, peak) = Repository.reduceWorkoutHr(samples([120, 121]))
        XCTAssertEqual(avg, 121)
        XCTAssertEqual(peak, 121)
    }

    /// A flat trace reduces to that value for both mean and peak.
    func testReduceFlatTrace() {
        let (avg, peak) = Repository.reduceWorkoutHr(samples(Array(repeating: 75, count: 8000)))
        XCTAssertEqual(avg, 75)
        XCTAssertEqual(peak, 75)
    }

    /// Single sample → that sample is both the mean and the peak.
    func testReduceSingleSample() {
        let (avg, peak) = Repository.reduceWorkoutHr(samples([88]))
        XCTAssertEqual(avg, 88)
        XCTAssertEqual(peak, 88)
    }

    /// The helper is `nonisolated static`, so it runs OFF the main actor when dispatched from a detached
    /// task (the whole point of the freeze fix: the up-to-8000-int sum/max must not run on the actor that
    /// drives the UI). Assert both that it executes off the main thread AND returns the right numbers there.
    func testReduceRunsOffMainActor() async {
        let input = samples((0..<8000).map { 60 + ($0 % 40) })
        let result: (offMain: Bool, avg: Int, peak: Int) = await Task.detached {
            let onMain = Thread.isMainThread
            let (avg, peak) = Repository.reduceWorkoutHr(input)
            return (offMain: !onMain, avg: avg, peak: peak)
        }.value
        XCTAssertTrue(result.offMain, "reduceWorkoutHr must run off the main thread (freeze fix)")
        XCTAssertEqual(result.peak, 99)            // 60 + 39
        XCTAssertGreaterThanOrEqual(result.avg, 60)
        XCTAssertLessThanOrEqual(result.avg, 99)
    }
}
