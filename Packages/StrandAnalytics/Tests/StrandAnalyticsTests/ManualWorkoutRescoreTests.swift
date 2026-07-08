import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #137 — the pure re-score logic: recompute an under-sampled manual workout's metrics from the denser
/// HR now available for its window, conservatively and idempotently.
final class ManualWorkoutRescoreTests: XCTestCase {

    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")

    /// A dense, moderately-hard window scores real calories + strain (the 5/MG case after offload).
    func testScoresDenseWindow() {
        // 20 minutes at ~140 bpm, 1 Hz.
        let samples = (0..<1200).map { HRSample(ts: 1_000 + $0, bpm: 140) }
        let s = ManualWorkoutRescore.scored(windowSamples: samples, profile: profile, hrMax: 190)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.avgHr, 140)
        XCTAssertEqual(s?.maxHr, 140)
        XCTAssertNotNil(s?.kcal)
        XCTAssertGreaterThan(s?.kcal ?? 0, 50)   // a 20-min Z3 bout burns well over 50 kcal
        XCTAssertNotNil(s?.strain)
    }

    /// #499 — Avg HR is the TRUE arithmetic mean of the actual HR trace, not a zone-weighted or partial
    /// estimate. This is the property that keeps the displayed average consistent with the graph / zones
    /// / effort (all of which read the same per-second samples). A varied trace (so a zone-weighted or
    /// truncated average would give a different answer) must still come out as the plain mean.
    func testAvgHrIsTrueMeanOfVariedTrace() {
        // Asymmetric ramp: 60 s climbing 100→159 then 60 s at 180. Plain mean ≠ midpoint, ≠ peak, ≠ any
        // zone-weighted figure — only the arithmetic mean of every sample is correct.
        let climb = (0..<60).map { HRSample(ts: 1_000 + $0, bpm: 100 + $0) }   // 100,101,…,159
        let hold  = (0..<60).map { HRSample(ts: 1_060 + $0, bpm: 180) }         // 180 ×60
        let samples = climb + hold
        let expectedMean = Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
        let s = ManualWorkoutRescore.scored(windowSamples: samples, profile: profile, hrMax: 190)
        XCTAssertEqual(s?.avgHr, expectedMean)          // == mean of the trace (154.75 → 155)
        XCTAssertEqual(s?.maxHr, 180)                   // == true peak of the trace
        XCTAssertNotEqual(s?.avgHr, 180)                // NOT the peak
        XCTAssertNotEqual(s?.avgHr, (100 + 180) / 2)    // NOT the min/max midpoint
    }

    /// Too few samples → nil (nothing better than what we had; never fabricate from one reading).
    func testTooFewSamplesReturnsNil() {
        XCTAssertNil(ManualWorkoutRescore.scored(windowSamples: [HRSample(ts: 1, bpm: 130)],
                                                 profile: profile, hrMax: 190))
        XCTAssertNil(ManualWorkoutRescore.scored(windowSamples: [], profile: profile, hrMax: 190))
    }

    /// The under-scored gate: only missing/negligible calories qualify; a normal workout never does.
    func testLooksUnderScoredGate() {
        XCTAssertTrue(ManualWorkoutRescore.looksUnderScored(currentKcal: nil))
        XCTAssertTrue(ManualWorkoutRescore.looksUnderScored(currentKcal: 1.0))   // the "1 kcal" symptom
        XCTAssertTrue(ManualWorkoutRescore.looksUnderScored(currentKcal: 5.0))
        XCTAssertFalse(ManualWorkoutRescore.looksUnderScored(currentKcal: 5.01))
        XCTAssertFalse(ManualWorkoutRescore.looksUnderScored(currentKcal: 250))  // a real session
    }

    /// Only persists a strict improvement — so a sparse-window recompute (≈ current) is a no-op, the
    /// pass is idempotent, and it can never *lower* a workout's numbers.
    func testImprovesIsStrictAndMonotonic() {
        let big = ManualWorkoutRescore.Scored(avgHr: 140, maxHr: 150, strain: 12, kcal: 220)
        XCTAssertTrue(ManualWorkoutRescore.improves(big, over: nil))
        XCTAssertTrue(ManualWorkoutRescore.improves(big, over: 1))
        XCTAssertFalse(ManualWorkoutRescore.improves(big, over: 220))   // already this good → no churn
        XCTAssertFalse(ManualWorkoutRescore.improves(big, over: 219.5)) // within the margin → no churn

        let none = ManualWorkoutRescore.Scored(avgHr: 0, maxHr: 0, strain: nil, kcal: nil)
        XCTAssertFalse(ManualWorkoutRescore.improves(none, over: 1))    // no recompute ⇒ never replace
    }

    /// The merged-row case: a merged workout's kcal is the SUM of its inputs, so it never looks
    /// under-scored, yet WorkoutMerge leaves its strain nil. A recompute that produces a strain must be
    /// accepted as a STRAIN-ONLY improvement even when its kcal does NOT beat the summed value, otherwise
    /// Effort stays blank forever. And once strain exists, a re-run is a no-op (idempotent).
    func testStrainOnlyImprovementFillsMergedRow() {
        // Recompute yields a strain but a MODEST kcal that does not beat the merged sum (e.g. 300).
        let recomputed = ManualWorkoutRescore.Scored(avgHr: 130, maxHr: 150, strain: 9, kcal: 120)
        let summedKcal: Double? = 300   // merged: SUM of inputs, well past the under-scored gate

        // Strain missing on the stored row → accept (fill Effort), even though kcal < summed sum.
        XCTAssertTrue(ManualWorkoutRescore.improves(recomputed, over: summedKcal,
                                                    currentStrain: nil, allowStrainOnlyFill: true))
        // Strain already present → no churn (kcal doesn't beat the sum, strain isn't missing).
        XCTAssertFalse(ManualWorkoutRescore.improves(recomputed, over: summedKcal,
                                                     currentStrain: 9, allowStrainOnlyFill: true))

        // A recompute with NO strain can't fill anything → still no-op.
        let noStrain = ManualWorkoutRescore.Scored(avgHr: 0, maxHr: 0, strain: nil, kcal: 120)
        XCTAssertFalse(ManualWorkoutRescore.improves(noStrain, over: summedKcal,
                                                     currentStrain: nil, allowStrainOnlyFill: true))

        // The strain-only path is OPT-IN: without the flag the contract is unchanged (kcal-only), so a
        // missing-strain row does NOT qualify on a 2-arg call, and the existing rescore path is untouched.
        XCTAssertFalse(ManualWorkoutRescore.improves(recomputed, over: summedKcal))
        XCTAssertFalse(ManualWorkoutRescore.improves(recomputed, over: summedKcal, currentStrain: nil))
    }

    /// End-to-end shape of the fix: a workout saved with ~1 kcal (sparse live HR) gets rescored from a
    /// dense offloaded window, and the result both clears the under-scored gate and improves.
    func testUnderScoredWorkoutGetsRescoredFromDenseWindow() {
        let stored: Double? = 1.0
        XCTAssertTrue(ManualWorkoutRescore.looksUnderScored(currentKcal: stored))
        let dense = (0..<900).map { HRSample(ts: 2_000 + $0, bpm: 150) }   // 15 min @150
        let s = ManualWorkoutRescore.scored(windowSamples: dense, profile: profile, hrMax: 190)!
        XCTAssertTrue(ManualWorkoutRescore.improves(s, over: stored))
        // And it's idempotent: re-running over the now-good value is a no-op.
        XCTAssertFalse(ManualWorkoutRescore.improves(s, over: s.kcal))
    }
}
