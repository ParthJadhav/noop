import XCTest
@testable import StrandAnalytics

final class IllnessDistanceTests: XCTestCase {

    // MARK: - Golden distances (hand-computed)

    func testIdentityDistanceIsEuclideanNorm() {
        // With no correlation supplied (identity), D == the Euclidean norm of the z-vector.
        // x = [3, 3] (two features both illness-ward) → D = sqrt(9 + 9) = 4.2426406871...
        let r = IllnessDistance.evaluate(
            features: .init(restingHR: 3.0, rmssd: 3.0))
        XCTAssertEqual(r.distance, 4.242640687119285, accuracy: 1e-6)
        XCTAssertEqual(r.deviatingFeatures, 2)
        XCTAssertFalse(r.usedDiagonalFallback)
        XCTAssertTrue(r.fires, "D > 2.5 and 2 deviating features → fires")
    }

    func testCorrelationDiscountsSharedVariance() {
        // Two POSITIVELY-correlated features both up should count as LESS of a joint anomaly than if treated
        // independently, Mahalanobis with a 0.8 correlation shrinks the distance from 4.24 to ~3.16.
        let corr = [[1.0, 0.8], [0.8, 1.0]]
        let indep = IllnessDistance.evaluate(features: .init(restingHR: 3.0, rmssd: 3.0))
        let correlated = IllnessDistance.evaluate(features: .init(restingHR: 3.0, rmssd: 3.0),
                                                  correlation: corr)
        XCTAssertEqual(correlated.distance, 3.162276781758283, accuracy: 1e-5)
        XCTAssertLessThan(correlated.distance, indep.distance,
                          "correlated co-movement counts as one move, not two")
    }

    // MARK: - Deviating-feature gate (a big D from a wellness-ward signal must not fire)

    func testWellnessWardSignalDoesNotCountAsDeviating() {
        // x = [3, -3]: one feature illness-ward, one strongly the WELLNESS way. The distance is large but
        // only ONE feature is deviating illness-ward → below minDeviatingFeatures(2) → does not fire.
        let corr = [[1.0, 0.8], [0.8, 1.0]]
        let r = IllnessDistance.evaluate(features: .init(restingHR: 3.0, rmssd: -3.0), correlation: corr)
        XCTAssertGreaterThan(r.distance, IllnessDistance.distanceThreshold)
        XCTAssertEqual(r.deviatingFeatures, 1)
        XCTAssertFalse(r.fires, "a big D driven by a wellness-ward coordinate must not fire")
    }

    func testEmptyVectorDoesNotFire() {
        let r = IllnessDistance.evaluate(features: .init())
        XCTAssertEqual(r.distance, 0)
        XCTAssertEqual(r.deviatingFeatures, 0)
        XCTAssertFalse(r.fires)
    }

    // MARK: - Singular correlation → diagonal fallback (no NaN)

    func testSingularCorrelationIsRegularizedToFinite() {
        // A perfectly collinear (rank-1) correlation is singular; the Tikhonov ridge regularizes it to a
        // FINITE distance (no NaN/Inf), and collinear co-movement is correctly discounted, two perfectly
        // correlated features both up count as ONE effective move, so D is well below the independent 4.24.
        let singular = [[1.0, 1.0], [1.0, 1.0]]
        let r = IllnessDistance.evaluate(features: .init(restingHR: 3.0, rmssd: 3.0), correlation: singular)
        XCTAssertTrue(r.distance.isFinite)
        XCTAssertGreaterThan(r.distance, 0)
        XCTAssertLessThan(r.distance, 4.2426, "collinear co-movement is one effective move, not two")
    }

    func testDiagonalFallbackOnDegenerateMatrix() {
        // Directly exercise the singular fallback path: a zero matrix has no usable pivot, so invertOrDiagonal
        // returns its finite diagonal inverse (degenerate diagonals mapped to 1) rather than NaN/Inf.
        let (inv, fellBack) = IllnessDistance.invertOrDiagonal([[0.0, 0.0], [0.0, 0.0]])
        XCTAssertTrue(fellBack)
        XCTAssertTrue(inv.allSatisfy { $0.allSatisfy { $0.isFinite } })
    }

    // MARK: - Fire-rate comparison vs the existing per-signal z-sum (REQUIRED by the lane spec)

    /// A deterministic illness test corpus of illness-oriented z-vectors covering: strong multi-signal
    /// nights, mild 2-signal nights, single-noisy-signal nights, and normal nights. The Mahalanobis path
    /// (identity correlation, the additive default with no personal corr supplied) must NOT balloon or
    /// silence alerts relative to the current per-signal z-sum corroboration gate at the 2.5 threshold.
    func testMahalanobisFireRateDoesNotBalloonOrSilence() {
        let corpus = Self.illnessCorpus()

        // Current per-signal scorer's RAISE precondition: >= 2 features over the z firing threshold (the
        // corroboration gate that gates a raised illness alert in IllnessSignalEngine).
        func zSumFires(_ v: [Double]) -> Bool {
            v.filter { $0 >= IllnessDistance.featureZThreshold }.count >= IllnessDistance.minDeviatingFeatures
        }
        // Alternative Mahalanobis path (identity corr): D > 2.5 AND >= 2 deviating features.
        func mahaFires(_ v: [Double]) -> Bool {
            IllnessDistance.evaluate(features: .init(
                restingHR: v[0], rmssd: v[1], skinTemp: v[2], respiration: v[3])).fires
        }

        let zCount = corpus.filter(zSumFires).count
        let mCount = corpus.filter(mahaFires).count
        XCTAssertGreaterThan(corpus.count, 0)
        // The alternative must stay in the same ballpark: neither more than ~25% above nor below the z-sum
        // fire-count. On this corpus they match exactly (any 2 features at z>=2 give D>=sqrt(8)>2.5), proving
        // the additive path neither cries wolf more nor goes silent.
        let lower = Int((Double(zCount) * 0.75).rounded(.down))
        let upper = Int((Double(zCount) * 1.25).rounded(.up))
        XCTAssertGreaterThanOrEqual(mCount, lower, "Mahalanobis path must not SILENCE alerts vs the z-sum")
        XCTAssertLessThanOrEqual(mCount, upper, "Mahalanobis path must not BALLOON alerts vs the z-sum")

        // And on every case the two agree on this corpus, strong evidence it's a faithful alternative.
        for v in corpus {
            XCTAssertEqual(zSumFires(v), mahaFires(v), "z-sum and Mahalanobis disagree on \(v)")
        }
    }

    /// 60-case deterministic corpus (no RNG so it's byte-stable across platforms): 15 strong, 15 mild
    /// 2-signal, 15 single-noisy, 15 normal nights, each a [rhr, rmssdNeg, skinTemp, resp] z-vector.
    static func illnessCorpus() -> [[Double]] {
        var c: [[Double]] = []
        // Strong multi-signal illness nights (3-4 features well over 2).
        c.append(contentsOf: [
            [3.2, 3.0, 3.5, 2.8], [4.1, 2.9, 3.3, 3.0], [2.6, 3.4, 2.7, 2.5],
            [3.8, 4.0, 3.9, 3.6], [2.9, 2.8, 3.1, 0.4], [3.5, 3.2, 0.2, 3.0],
            [4.4, 0.1, 3.0, 2.7], [2.7, 3.6, 3.4, 1.1], [3.0, 3.0, 3.0, 3.0],
            [2.5, 2.6, 2.9, 2.4], [3.9, 3.1, 1.0, 2.8], [3.3, 0.5, 3.2, 3.4],
            [2.8, 3.7, 2.6, 0.3], [4.0, 2.5, 2.5, 2.5], [3.1, 3.3, 3.5, 3.7],
        ])
        // Mild 2-signal nights (exactly two over 2, others quiet).
        c.append(contentsOf: [
            [2.3, 2.2, 0.5, -0.4], [2.1, 0.3, 2.4, 1.0], [0.2, 2.6, 2.1, -1.0],
            [2.5, 1.1, 0.0, 2.2], [2.2, 2.3, -0.5, 0.7], [1.0, 2.1, 2.7, 0.1],
            [2.4, 0.4, 1.2, 2.3], [2.6, 2.2, 1.5, -0.2], [0.6, 2.5, 0.3, 2.1],
            [2.1, 1.0, 2.2, 0.5], [2.3, 2.4, 0.8, 1.1], [1.2, 2.2, 2.5, 0.0],
            [2.7, 0.1, 2.1, 1.3], [2.2, 2.6, -0.3, 0.9], [0.4, 2.3, 2.2, 1.0],
        ])
        // Single-noisy-signal nights (one big, rest quiet → must not fire either way).
        c.append(contentsOf: [
            [5.0, 0.5, -0.2, 1.0], [0.3, 4.5, 1.1, -0.5], [1.2, -1.0, 3.8, 0.4],
            [0.7, 1.0, 0.2, 4.2], [6.0, -0.5, 0.8, 1.2], [1.5, 5.5, -0.3, 0.6],
            [-0.4, 0.9, 4.9, 1.0], [1.1, 0.2, 1.0, 5.1], [3.2, 1.0, 1.5, 0.5],
            [0.8, 3.5, 1.2, 1.0], [1.0, 0.6, 3.1, 1.4], [1.3, 1.0, 0.7, 3.6],
            [4.7, 1.4, 1.0, 0.3], [0.9, 4.0, 0.5, 1.1], [1.0, 0.8, 4.4, 0.9],
        ])
        // Normal nights (nothing over 2).
        c.append(contentsOf: [
            [0.5, -0.3, 1.2, 0.8], [-1.0, 0.4, 0.6, 1.5], [1.8, 1.0, -0.5, 0.2],
            [0.0, 1.9, 1.1, -1.2], [1.5, -0.8, 0.9, 1.0], [-0.4, 1.2, 1.7, 0.3],
            [1.1, 0.5, -0.2, 1.6], [0.7, 1.8, 0.4, 0.9], [-1.5, 0.6, 1.3, 1.0],
            [1.0, 1.0, 1.0, 1.0], [0.3, -0.5, 1.9, 0.7], [1.6, 1.1, 0.2, -0.6],
            [0.9, 1.7, 1.0, 1.2], [-0.2, 0.8, 1.5, 1.8], [1.4, 1.3, -1.0, 0.5],
        ])
        return c
    }
}
