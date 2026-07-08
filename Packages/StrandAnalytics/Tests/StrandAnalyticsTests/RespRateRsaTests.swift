import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Tests SleepStager.respRateFromRR (RSA) on a synthetic R-R series with a KNOWN breathing
/// frequency. WHOOP5 v18 carries no raw resp ADC, so respiratory rate is derived on-device
/// from the R-R stream via respiratory sinus arrhythmia; this pins that the estimator recovers
/// a planted breathing rate and returns NaN on too-little data (honest no-data). The value is
/// an APPROXIMATE on-device estimate, not cloud/clinical respiration. Mirrors the Android
/// RespRateRsaTest vectors value-for-value.
final class RespRateRsaTests: XCTestCase {

    func testRespRateFromRRRecoversKnownBreathingFrequency() {
        // Synthetic RR: mean HR 60 bpm (RR ~1000 ms) with a 0.25 Hz (15 breaths/min)
        // RSA modulation of +/-40 ms. ~7 minutes of beats so multiple 5-min windows.
        let breathHz = 0.25  // 15 breaths/min
        let baseRrMs = 1000.0
        let ampMs = 40.0
        let start = 1_700_000_000
        var rows: [RRInterval] = []
        var tSec = 0.0
        // generate ~420 s of beats
        while tSec < 420.0 {
            let rrMs = baseRrMs + ampMs * sin(2.0 * Double.pi * breathHz * tSec)
            tSec += rrMs / 1000.0
            rows.append(RRInterval(ts: start + Int(tSec), rrMs: Int(rrMs)))
        }
        let end = start + Int(tSec)
        let est = SleepStager.respRateFromRR(rows, start: start, end: end)
        XCTAssertTrue(est.isFinite, "expected finite resp estimate, got \(est)")
        // RSA peak-pick should land within ~3 bpm of the true 15 breaths/min.
        XCTAssertEqual(est, 15.0, accuracy: 3.0)
    }

    /// #958 regression: a slow breather (11 breaths/min, the value in the report) must read back
    /// ~11, NOT the doubled ~20-21 the reporter saw. RSA peak-picking has a known failure mode where
    /// a split / harmonic peak per breath can inflate the rate toward 2x; this pins that the median
    /// across windows stays on the fundamental. Guards the exact factor rather than blindly halving.
    func testRespRateFromRRSlowBreatherIsNotDoubled() {
        // Mean HR 55 bpm (RR ~1091 ms), 11 breaths/min (0.1833 Hz), +/-45 ms RSA, ~8 min of beats.
        let breathHz = 11.0 / 60.0
        let baseRrMs = 60000.0 / 55.0
        let ampMs = 45.0
        let start = 1_700_000_000
        var rows: [RRInterval] = []
        var tSec = 0.0
        while tSec < 480.0 {
            let rrMs = baseRrMs + ampMs * sin(2.0 * Double.pi * breathHz * tSec)
            tSec += rrMs / 1000.0
            rows.append(RRInterval(ts: start + Int(tSec), rrMs: Int(rrMs)))
        }
        let end = start + Int(tSec)
        let est = SleepStager.respRateFromRR(rows, start: start, end: end)
        XCTAssertTrue(est.isFinite, "expected finite resp estimate, got \(est)")
        // Must land on the true 11 breaths/min, well below the ~20-21 doubling in #958.
        XCTAssertEqual(est, 11.0, accuracy: 2.0)
        XCTAssertLessThan(est, 16.0, "resp estimate must not be doubled toward ~22 (#958)")
    }

    func testRespRateFromRRTooFewBeatsIsNaN() {
        let start = 1_700_000_000
        let rows = [
            RRInterval(ts: start + 1, rrMs: 1000),
            RRInterval(ts: start + 2, rrMs: 1000),
            RRInterval(ts: start + 3, rrMs: 1000),
        ]
        XCTAssertTrue(SleepStager.respRateFromRR(rows, start: start, end: start + 10).isNaN)
        XCTAssertTrue(SleepStager.respRateFromRR([], start: start, end: start + 10).isNaN)
    }
}
