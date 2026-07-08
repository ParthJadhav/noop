import Foundation
import WhoopProtocol

// HRVFreqDomain.swift, frequency-domain HRV (LF / HF / LF-HF / total power) over an R-R series.
//
// PURELY ADDITIVE. This file introduces NO change to any Charge / Effort / Rest / sleep output; it is a
// brand-new, opt-in estimator the UI lanes surface later. The existing time-domain HRVAnalyzer (RMSSD /
// SDNN / pNN50) is untouched.
//
// WHY LOMB-SCARGLE, NOT AN FFT. A tachogram (the series of successive R-R intervals plotted against their
// own cumulative time) is UNEVENLY sampled by construction: each interval's timestamp is the running sum of
// the preceding intervals, so the samples are not on a fixed grid. The classical HRV pipeline resamples the
// tachogram onto a uniform grid (e.g. 4 Hz) and runs an FFT, but that resampling is itself a low-pass
// interpolation that distorts the high-frequency (HF / respiratory) band, exactly the band that matters
// most for parasympathetic tone. The Lomb-Scargle periodogram (Lomb 1976, Scargle 1982) estimates the power
// spectrum DIRECTLY from the unevenly sampled points with no interpolation, and is the estimator recommended
// for HRV on irregular tachograms (Laguna, Moody & Mark 1998; Clifford & Tarassenko 2005). So we compute it
// directly on the (t_k, rr_k) pairs.
//
// This generalises the band-limited DFT already used in SleepStagerV2.respRegularity (a uniform-grid DFT
// restricted to the respiratory band): here the same "evaluate the spectrum only at the bins/frequencies we
// care about" idea is applied, but with the Lomb-Scargle estimator so no resampling is needed and arbitrary
// frequencies (the LF/HF band edges) can be probed.
//
// TASK FORCE (1996) BANDS AND SPAN GATES:
//   • VLF  : 0.0033–0.04 Hz  (folded into total power only; not reported on its own, needs many minutes)
//   • LF   : 0.04–0.15  Hz   (~7–37 s period)
//   • HF   : 0.15–0.40  Hz   (~2.5–6.7 s period; the respiratory band)
//   • LF/HF: the ratio of the two band powers.
//
// A periodogram can only resolve a frequency whose period fits inside the record several times. The Task
// Force short-term standard is a 5-minute (300 s) recording; we relax that to honest MINIMUM spans:
//   • HF needs >= 60 s of R-R span (its slowest component, 0.15 Hz, is a ~6.7 s period, ~9 cycles in 60 s).
//   • LF (and therefore LF/HF and a meaningful total power) needs >= 250 s of span (its slowest component,
//     0.04 Hz, is a 25 s period, only ~10 cycles even at 250 s; below that the LF estimate is unreliable).
// Below 60 s of span the whole result is nil; between 60 s and 250 s HF is returned but LF / LF-HF are nil.
//
// APPROXIMATE, non-clinical. Units are ms^2 (power of an R-R series in ms), the conventional HRV unit.

public enum HRVFreqDomain {

    // MARK: - Band edges (Hz) and span gates (s), pinned by test, mirrored in the Kotlin twin.

    /// VLF lower edge (Hz). Folded into total power; not reported alone.
    public static let vlfLowHz: Double = 0.0033
    /// LF band: [0.04, 0.15] Hz.
    public static let lfLowHz: Double = 0.04
    public static let lfHighHz: Double = 0.15
    /// HF band: [0.15, 0.40] Hz.
    public static let hfLowHz: Double = 0.15
    public static let hfHighHz: Double = 0.40

    /// Minimum R-R span (s) before ANY frequency-domain result is returned (HF needs at least this).
    public static let minSpanForHFSec: Double = 60.0
    /// Minimum R-R span (s) before the LF band (and LF/HF, total power) is trusted; below this they are nil.
    public static let minSpanForLFSec: Double = 250.0

    /// Minimum clean intervals before a spectrum is attempted at all (a handful of beats has no spectrum).
    public static let minBeats: Int = 20

    /// Frequency-grid resolution (Hz) at which the Lomb-Scargle periodogram is sampled within each band.
    /// 0.005 Hz puts ~22 grid points across LF and ~50 across HF, fine enough for a stable band integral
    /// without the cost of a full-resolution spectrum. The band power is a trapezoidal integral over the grid.
    public static let freqStepHz: Double = 0.005

    // MARK: - Result

    /// Frequency-domain HRV over a window. `lf` / `lfhf` are nil when the span is too short for the LF band
    /// (60 s <= span < 250 s gives HF only). `hf` and `totalPower` are present whenever the result is non-nil
    /// (i.e. span >= 60 s). All powers are in ms^2.
    public struct Bands: Equatable, Sendable {
        /// LF band power (0.04–0.15 Hz), ms^2. nil when span < 250 s.
        public let lf: Double?
        /// HF band power (0.15–0.40 Hz), ms^2. Always present on a non-nil result.
        public let hf: Double
        /// LF / HF ratio (dimensionless). nil when LF is nil or HF == 0.
        public let lfhf: Double?
        /// Total power across VLF+LF+HF (0.0033–0.40 Hz), ms^2. The wide band is only meaningful once the
        /// span supports LF; on a HF-only (short) window this reports the HF-band power so the field is never
        /// a misleading partial sum.
        public let totalPower: Double

        public init(lf: Double?, hf: Double, lfhf: Double?, totalPower: Double) {
            self.lf = lf; self.hf = hf; self.lfhf = lfhf; self.totalPower = totalPower
        }
    }

    // MARK: - Public API

    /// Frequency-domain HRV from R-R intervals (each carrying its own wall-clock `ts` in seconds and `rrMs`).
    /// The series is cleaned with the SAME range + Malik ectopic pipeline the time-domain analyzer uses
    /// (`HRVAnalyzer.cleanRR`) before the tachogram is built, so an artifact beat cannot inject spurious
    /// power. Returns nil when there are too few clean beats or the R-R span is under `minSpanForHFSec`.
    public static func freqDomain(rr: [RRInterval]) -> Bands? {
        let raw = rr.sorted { $0.ts < $1.ts }.map { Double($0.rrMs) }
        return freqDomain(rawRR: raw)
    }

    /// Frequency-domain HRV from a raw, time-ordered R-R series in milliseconds. The cumulative-sum of the
    /// CLEANED intervals (in seconds) forms each sample's timestamp on the tachogram; the cleaned R-R values
    /// (mean-removed) are the samples. Returns nil under the same gates as the `[RRInterval]` overload.
    public static func freqDomain(rawRR: [Double]) -> Bands? {
        let clean = HRVAnalyzer.cleanRR(rawRR)
        guard clean.count >= minBeats else { return nil }

        // Build the tachogram: time of beat k = cumulative sum of the first k clean R-R intervals (seconds).
        // Sample value at that time = the R-R interval itself (ms). This is the standard HRV tachogram.
        var times = [Double](repeating: 0, count: clean.count)
        var acc = 0.0
        for i in 0..<clean.count {
            times[i] = acc / 1000.0      // ms -> s
            acc += clean[i]
        }
        let span = times.last! - times.first!   // total record length in seconds
        guard span >= minSpanForHFSec else { return nil }

        // Mean-remove the R-R series; Lomb-Scargle assumes a zero-mean signal (it removes a DC offset that
        // would otherwise leak across all frequencies).
        let mean = clean.reduce(0, +) / Double(clean.count)
        let y = clean.map { $0 - mean }

        // HF band power is always computable once span >= 60 s.
        let hf = bandPower(times: times, y: y, fLow: hfLowHz, fHigh: hfHighHz)

        // LF (and so LF/HF and the wide total power) only once span >= 250 s.
        let lfTrusted = span >= minSpanForLFSec
        let lf: Double? = lfTrusted ? bandPower(times: times, y: y, fLow: lfLowHz, fHigh: lfHighHz) : nil

        let lfhf: Double?
        if let lf, hf > 0 { lfhf = lf / hf } else { lfhf = nil }

        // Total power = the SUM of the sub-band integrals (VLF + LF + HF) when LF is trusted, otherwise just
        // the HF band. Summing the bands (rather than one wide [VLF..HF] integral) guarantees totalPower >= hf
        // and keeps it grid-consistent with the reported bands: a single wide integral samples the spectrum on
        // a grid offset from the HF-only grid, so for a narrow peak it can undercount the HF region and fall
        // below `hf`, which is physically impossible for a superset band.
        let totalPower: Double
        if lfTrusted, let lfVal = lf {
            let vlf = bandPower(times: times, y: y, fLow: vlfLowHz, fHigh: lfLowHz)
            totalPower = vlf + lfVal + hf
        } else {
            totalPower = hf
        }

        return Bands(lf: lf, hf: hf, lfhf: lfhf, totalPower: totalPower)
    }

    // MARK: - Lomb-Scargle band integral

    /// Trapezoidal integral of the Lomb-Scargle power across [fLow, fHigh], sampled every `freqStepHz`.
    /// Returns 0 for a degenerate band. The Lomb-Scargle normalisation used here is the classic Press et al.
    /// (Numerical Recipes) form; we integrate it over frequency so the result is a band POWER (ms^2),
    /// proportional across bands and stable under the chosen grid.
    static func bandPower(times: [Double], y: [Double], fLow: Double, fHigh: Double) -> Double {
        guard fHigh > fLow else { return 0 }
        // Variance of the (already mean-removed) signal; Lomb-Scargle scales power by it.
        let n = Double(y.count)
        var variance = 0.0
        for v in y { variance += v * v }
        variance /= n
        guard variance > 0 else { return 0 }

        var power = 0.0
        var prevP = 0.0
        var prevF = fLow
        var first = true
        var f = fLow
        while f <= fHigh + 1e-12 {
            let p = lombScarglePower(times: times, y: y, freqHz: f, variance: variance)
            if !first {
                // Trapezoid: average of the two endpoint powers times the frequency step, in (ms^2/Hz)*Hz.
                power += 0.5 * (p + prevP) * (f - prevF)
            }
            prevP = p
            prevF = f
            first = false
            f += freqStepHz
        }
        return power
    }

    /// Lomb-Scargle normalised power at a single angular frequency (Press et al., Numerical Recipes form).
    /// `variance` is the sample variance of the mean-removed series. The time-offset tau makes the estimate
    /// invariant to time translation, which is what lets it handle the uneven tachogram spacing correctly.
    static func lombScarglePower(times: [Double], y: [Double], freqHz: Double, variance: Double) -> Double {
        let omega = 2.0 * Double.pi * freqHz

        // tau: the phase offset that orthogonalises the sine and cosine sums (Lomb 1976, eq. for tau).
        var sin2 = 0.0, cos2 = 0.0
        for t in times {
            let a = 2.0 * omega * t
            sin2 += sin(a)
            cos2 += cos(a)
        }
        let tau = atan2(sin2, cos2) / (2.0 * omega)

        var cTerm = 0.0, cDen = 0.0
        var sTerm = 0.0, sDen = 0.0
        for i in 0..<times.count {
            let arg = omega * (times[i] - tau)
            let c = cos(arg)
            let s = sin(arg)
            cTerm += y[i] * c
            cDen += c * c
            sTerm += y[i] * s
            sDen += s * s
        }
        let cosPart = cDen > 0 ? (cTerm * cTerm) / cDen : 0.0
        let sinPart = sDen > 0 ? (sTerm * sTerm) / sDen : 0.0
        // Normalised by 2*variance so the spectrum is a power-spectral-density estimate in ms^2/Hz.
        return (cosPart + sinPart) / (2.0 * variance)
    }
}
