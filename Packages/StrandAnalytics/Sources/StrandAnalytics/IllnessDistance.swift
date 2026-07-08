import Foundation

// IllnessDistance.swift, an ALTERNATIVE, multivariate illness-anomaly distance (Mahalanobis).
//
// PARALLEL PATH, NOT the default scorer. The shipped IllnessSignalEngine keeps its per-signal z-sum + ≥2
// corroboration + confounder suppression exactly as-is. This file adds a SECOND way to measure "how far is
// today's 4-signal vector from my personal baseline", behind an explicit flag, so the UI lane can A/B it
// without touching the live alert path. The default illness scorer is unchanged.
//
// WHY MAHALANOBIS. The four illness signals (RHR ↑, RMSSD ↓, skin-temp ↑, respiration ↑) are CORRELATED:
// when you are getting sick they tend to move together, and even at baseline RHR and respiration co-vary.
// Summing per-signal z-scores treats them as independent and so double-counts shared variance. The
// Mahalanobis distance
//
//     D^2 = (x - mu)^T * C^-1 * (x - mu)
//
// uses the inverse CORRELATION matrix C^-1 (we feed it z-scored features, so the covariance of z's is the
// correlation matrix) to discount that shared variance: two correlated signals both up counts as ONE
// coordinated move, not two. D is in "standard-deviation-equivalent" units, so a threshold of 2.5 is
// comparable to the existing per-signal z≈2 gate but accounts for the joint structure.
//
// HONEST GATING preserved: this distance is only one input. We keep NOOP's existing rules layered on top:
//   • fires only when D > distanceThreshold AND at least minDeviatingFeatures features are themselves
//     deviating ILLNESS-WARD (a large D driven by one signal pointing the WELLNESS way must not fire), and
//   • the caller still applies the same confounder suppression (alcohol / travel / etc.) afterwards.
//
// The correlation inverse is solved by Gauss-Jordan elimination; if the matrix is singular (or near-so) we
// fall back to the DIAGONAL inverse (i.e. treat features as independent, which degrades gracefully to the
// per-signal behaviour rather than producing NaNs).
//
// Pure, deterministic, DB-free. APPROXIMATE, non-clinical, never names a condition.

public enum IllnessDistance {

    /// Mahalanobis distance D above which the alternative path considers firing (before the deviating-feature
    /// gate and the caller's confounder suppression). Comparable to the existing per-signal z≈2 firing gate
    /// but in joint standard-deviation units.
    public static let distanceThreshold: Double = 2.5

    /// Minimum features that must themselves point ILLNESS-WARD (positive z) before a large D can fire, the
    /// same ≥2 corroboration spirit as IllnessSignalEngine, so one coordinate can't carry the alert.
    public static let minDeviatingFeatures: Int = 2

    /// A feature counts as "deviating illness-ward" once its illness-oriented z reaches this (mirrors
    /// IllnessSignalEngine.signalZThreshold so the two paths agree on what "a signal is up" means).
    public static let featureZThreshold: Double = 2.0

    /// Ridge added to the correlation diagonal before inversion for numerical stability (a tiny Tikhonov
    /// term so a near-singular correlation from a short baseline still inverts). Does not meaningfully move a
    /// well-conditioned matrix.
    public static let ridge: Double = 1e-6

    /// The four illness signals, in fixed order, each as an illness-ORIENTED z (positive = more illness-like:
    /// RHR ↑, skin-temp ↑, respiration ↑ pass raw z; RMSSD ↓ passes the NEGATED z). nil = signal absent this
    /// window (dropped from the distance, and never counted as a deviating feature).
    public struct FeatureVector: Equatable, Sendable {
        public var restingHR: Double?
        public var rmssd: Double?       // already negated by the caller so positive == drop == illness-ward
        public var skinTemp: Double?
        public var respiration: Double?
        public init(restingHR: Double? = nil, rmssd: Double? = nil,
                    skinTemp: Double? = nil, respiration: Double? = nil) {
            self.restingHR = restingHR; self.rmssd = rmssd
            self.skinTemp = skinTemp; self.respiration = respiration
        }

        /// Present coordinates in fixed order (restingHR, rmssd, skinTemp, respiration).
        var present: [Double] {
            [restingHR, rmssd, skinTemp, respiration].compactMap { $0 }
        }
    }

    public struct Result: Equatable, Sendable {
        /// Mahalanobis distance D (sqrt of the quadratic form). 0 when no features present.
        public let distance: Double
        /// Count of present features whose illness-ward z >= featureZThreshold.
        public let deviatingFeatures: Int
        /// True iff D > distanceThreshold AND deviatingFeatures >= minDeviatingFeatures. The caller still
        /// applies confounder suppression on top of this before surfacing anything.
        public let fires: Bool
        /// True when the correlation matrix was singular and the diagonal-inverse fallback was used.
        public let usedDiagonalFallback: Bool

        public init(distance: Double, deviatingFeatures: Int, fires: Bool, usedDiagonalFallback: Bool) {
            self.distance = distance; self.deviatingFeatures = deviatingFeatures
            self.fires = fires; self.usedDiagonalFallback = usedDiagonalFallback
        }
    }

    /// Mahalanobis distance of today's illness-oriented z-vector from the personal baseline.
    ///
    /// Because the features are ALREADY z-scored against the personal baseline, the baseline mean is the
    /// zero vector and the covariance of the z's is the personal CORRELATION matrix. The caller supplies that
    /// correlation matrix as the symmetric `correlation` (rows/cols in the same fixed feature order over the
    /// PRESENT features). Pass the identity (or nil) to fall back to the independent-features case, which
    /// makes D == the Euclidean norm of the z-vector.
    ///
    /// - Parameters:
    ///   - features: today's illness-oriented z-vector (absent coordinates dropped).
    ///   - correlation: NxN personal correlation over the present features in fixed order, or nil for
    ///     identity. Must be square with side == features.present.count when non-nil.
    public static func evaluate(features: FeatureVector,
                                correlation: [[Double]]? = nil) -> Result {
        let x = features.present
        let k = x.count
        guard k > 0 else {
            return Result(distance: 0, deviatingFeatures: 0, fires: false, usedDiagonalFallback: false)
        }

        // Count features pointing illness-ward (z >= threshold) for the corroboration gate.
        var deviating = 0
        for v in x where v >= featureZThreshold { deviating += 1 }

        // Resolve the correlation matrix: caller-supplied (validated square) or identity.
        var corr: [[Double]]
        let suppliedCorrelation: Bool
        if let c = correlation, c.count == k, c.allSatisfy({ $0.count == k }) {
            corr = c; suppliedCorrelation = true
        } else {
            corr = identity(k); suppliedCorrelation = false
        }
        // Ridge the diagonal for conditioning, but ONLY a supplied correlation. The identity (nil) case
        // must invert to itself exactly so D equals the Euclidean norm of the z-vector to full precision;
        // adding a Tikhonov term there would shrink it by ~ridge and break the documented contract.
        if suppliedCorrelation { for i in 0..<k { corr[i][i] += ridge } }

        // Invert; on singularity fall back to the diagonal inverse (independent features).
        let (inv, fellBack) = invertOrDiagonal(corr)

        // Quadratic form x^T * inv * x (mean is zero since x is already a z-vector).
        var d2 = 0.0
        for i in 0..<k {
            var rowDot = 0.0
            for j in 0..<k { rowDot += inv[i][j] * x[j] }
            d2 += x[i] * rowDot
        }
        if d2 < 0 { d2 = 0 }   // guard tiny negative from rounding on a near-singular inverse.
        let distance = d2.squareRoot()

        let fires = distance > distanceThreshold && deviating >= minDeviatingFeatures
        return Result(distance: distance, deviatingFeatures: deviating,
                      fires: fires, usedDiagonalFallback: fellBack)
    }

    // MARK: - Linear algebra (Gauss-Jordan with diagonal fallback)

    static func identity(_ n: Int) -> [[Double]] {
        var m = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { m[i][i] = 1 }
        return m
    }

    /// Invert a square matrix by Gauss-Jordan with partial pivoting. Returns (inverse, fellBack=false) on
    /// success; on a (near-)singular pivot returns (diagonalInverse, fellBack=true) where the diagonal
    /// inverse is 1/diag (treating off-diagonals as zero), with any zero/sign-degenerate diagonal entry
    /// mapped to 1 so the result is the identity in that coordinate (graceful, never NaN/Inf).
    static func invertOrDiagonal(_ a: [[Double]]) -> (inverse: [[Double]], fellBack: Bool) {
        let n = a.count
        // Augment [a | I].
        var m = [[Double]](repeating: [Double](repeating: 0, count: 2 * n), count: n)
        for i in 0..<n {
            for j in 0..<n { m[i][j] = a[i][j] }
            m[i][n + i] = 1
        }
        let eps = 1e-12
        for col in 0..<n {
            // Partial pivot: largest |value| in this column at/below the diagonal.
            var pivotRow = col
            var pivotMag = abs(m[col][col])
            for r in (col + 1)..<n where abs(m[r][col]) > pivotMag {
                pivotMag = abs(m[r][col]); pivotRow = r
            }
            if pivotMag < eps {
                return (diagonalInverse(a), true)   // singular: fall back.
            }
            if pivotRow != col { m.swapAt(col, pivotRow) }
            let pivot = m[col][col]
            for j in 0..<(2 * n) { m[col][j] /= pivot }
            for r in 0..<n where r != col {
                let factor = m[r][col]
                if factor == 0 { continue }
                for j in 0..<(2 * n) { m[r][j] -= factor * m[col][j] }
            }
        }
        var inv = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in 0..<n { inv[i][j] = m[i][n + j] } }
        return (inv, false)
    }

    /// Diagonal inverse: 1/diag on the diagonal, zeros elsewhere. A non-positive diagonal entry maps to 1
    /// (identity in that coordinate) so the fallback is always finite.
    static func diagonalInverse(_ a: [[Double]]) -> [[Double]] {
        let n = a.count
        var inv = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            let d = a[i][i]
            inv[i][i] = d > 1e-12 ? 1.0 / d : 1.0
        }
        return inv
    }
}
