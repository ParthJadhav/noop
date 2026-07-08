import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Unit tests for the WHOOP 5.0/MG skin-temperature pipeline in AnalyticsEngine
/// (macOS parity with the Android SkinTempAnalyticsTest).
///
/// Two parts:
///  1. `AnalyticsEngine.wornNightlySkinTempC` — the wear-gated nightly-mean logic (the part
///     that turns raw skin_temp_raw@73 samples into a trustworthy per-night value).
///  2. The seed→deviation flow over `Baselines.foldHistory`/`Baselines.deviation` with the
///     standard `skin_temp` config — pinning the honest cold-start gate (<4 nights ⇒ no
///     skinTempDevC) and that a real elevation surfaces as a positive deviation once seeded.
///
/// SCALE NOTE: the firmware stores CENTIDEGREES in skin_temp_raw@73 — °C = raw/100, matching
/// the Android decoder/tests. (The earlier /128 "AS6221-native" assumption was disproven by the
/// real captures in Whoop5HistoricalTests: worn raw 3057 / off-wrist 2247 are 30.6 °C skin and
/// 22.5 °C room ambient under /100, but an impossible 23.9 °C "skin" under /128 — below the worn
/// gate, silently dropping every real night. PR #97 review / #166.) Worn nightly values on real
/// hardware are ~30–35 °C, off-wrist/charging ~22–27 °C — exactly the contamination the
/// wear-gate excludes. All values APPROXIMATE.
final class SkinTempAnalyticsTests: XCTestCase {

    private func session(start: Int, durSec: Int) -> SleepSession {
        SleepSession(start: start, end: start + durSec, efficiency: 0.9,
                     stages: [], restingHR: 50, avgHRV: 60.0)
    }

    private func hr(_ ts: Int, bpm: Int = 55) -> HRSample { HRSample(ts: ts, bpm: bpm) }
    /// raw = °C × 100 (centidegrees, firmware scale): 34 °C → 3400, 36 °C → 3600, 22 °C → 2200.
    private func skin(_ ts: Int, rawX100: Int) -> SkinTempSample { SkinTempSample(ts: ts, raw: rawX100) }

    // MARK: - wornNightlySkinTempC

    func testMeanOverWornInBedSamples() throws {
        let start = 1_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) }  // 34.00 °C
        let mean = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
        XCTAssertEqual(mean, 34.0, accuracy: 1e-9)
    }

    func testExcludesSamplesWithoutConcurrentWornHr() {
        // The strap streams HR only on-wrist; skin-temp samples with no concurrent worn BPM drop.
        let start = 2_000_000
        let sess = [session(start: start, durSec: 600)]
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) }
        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC(sess, hr: [], skinTemp: temps))
    }

    func testExcludesDaytimeSamplesOutsideTheSleepSession() throws {
        // Daytime samples are in worn range (36 °C) AND have worn HR, but fall OUTSIDE the in-bed
        // session window, so only the in-bed 34 °C samples count. Isolates the session-window gate.
        let night = 3_000_000
        let sess = [session(start: night, durSec: 600)]
        let inBedHr = (0..<600).map { hr(night + $0) }
        let inBedTemp = (0..<600).map { skin(night + $0, rawX100: 3400) }
        let day = night + 10_000
        let dayHr = (0..<600).map { hr(day + $0) }
        let dayTemp = (0..<600).map { skin(day + $0, rawX100: 3600) }  // 36 °C, worn-range, daytime
        let mean = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(
            sess, hr: inBedHr + dayHr, skinTemp: inBedTemp + dayTemp))
        XCTAssertEqual(mean, 34.0, accuracy: 1e-9)
    }

    func testExcludesOnChargerAmbientEvenInBed() {
        // Mid-night on charger: HR still has stray worn-range values but skin temp drifts to
        // ambient (~22 °C) — which passes the strap's looser decode gate but is below the worn
        // floor of 28 °C.
        let start = 4_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 2200) }  // 22 °C ambient
        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
    }

    func testBelowMinSamplesIsNil() {
        let start = 5_000_000
        let sess = [session(start: start, durSec: 100)]
        let hrs = (0..<100).map { hr(start + $0) }
        let temps = (0..<100).map { skin(start + $0, rawX100: 3400) }  // 100 < minSkinTempSamples
        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
    }

    func testEmptyInputsAreNil() {
        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC([], hr: [], skinTemp: []))
    }

    // MARK: - skin-temp funnel diagnostic (#752)

    /// The kept-path: the funnel's mean is byte-identical to `wornNightlySkinTempC`, and the drop buckets +
    /// kept sum to the total (every sample is accounted for exactly once).
    func testFunnelKeptPathMatchesMeanAndAccountsForEverySample() throws {
        let start = 6_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) }  // 34 °C, all worn + in-window
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps)
        XCTAssertEqual(f.totalSamples, 600)
        XCTAssertEqual(f.kept, 600)
        XCTAssertEqual(f.droppedNotWorn + f.droppedOutOfWindow + f.droppedOutOfRange + f.kept, f.totalSamples)
        XCTAssertEqual(try XCTUnwrap(f.mean), 34.0, accuracy: 1e-9)
        XCTAssertFalse(f.isAbsent)
        // The mean exactly matches the public wrapper (they share gate logic, so can't diverge).
        XCTAssertEqual(f.mean, AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
    }

    /// 4.0-style "skin temp absent" triage: samples exist but NONE are worn (no concurrent live HR), so the
    /// funnel attributes the whole loss to `droppedNotWorn` and the mean is absent.
    func testFunnelAllNotWornExplainsAbsence() {
        let start = 7_000_000
        let sess = [session(start: start, durSec: 600)]
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) }
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: [], skinTemp: temps)
        XCTAssertEqual(f.totalSamples, 600)
        XCTAssertEqual(f.droppedNotWorn, 600)
        XCTAssertEqual(f.kept, 0)
        XCTAssertTrue(f.isAbsent)
        XCTAssertTrue(f.summary.contains("notWorn=600"), "the summary names the dominant gate: \(f.summary)")
    }

    /// Worn + in-window samples that drift to ambient (~22 °C, on-charger) all fail the worn-range gate, so
    /// the loss is attributed to `droppedOutOfRange` - the user can see it was off-wrist drift, not a bug.
    func testFunnelOutOfRangeIsAttributedToRangeGate() {
        let start = 8_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 2200) }  // 22 °C ambient
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps)
        XCTAssertEqual(f.droppedOutOfRange, 600)
        XCTAssertEqual(f.droppedNotWorn, 0)
        XCTAssertEqual(f.kept, 0)
        XCTAssertTrue(f.isAbsent)
    }

    /// Worn samples outside every detected in-bed span are attributed to `droppedOutOfWindow`. With NO
    /// session at all, every sample is out of window (matching the old early-return-nil behaviour).
    func testFunnelOutOfWindowAndNoSession() {
        let start = 9_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + 100_000 + $0) }            // worn, but far from the session
        let temps = (0..<600).map { skin(start + 100_000 + $0, rawX100: 3400) }
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps)
        XCTAssertEqual(f.droppedOutOfWindow, 600)
        XCTAssertEqual(f.kept, 0)
        XCTAssertTrue(f.isAbsent)
        // No session → every sample is out of window, and the mean is absent (legacy early-return parity).
        let none = AnalyticsEngine.skinTempFunnel([], hr: hrs, skinTemp: temps)
        XCTAssertEqual(none.droppedOutOfWindow, 600)
        XCTAssertTrue(none.isAbsent)
    }

    /// Below the min-samples floor: every sample is kept but the mean is still absent (the last gate), and
    /// `kept` reports the survivor count so the user sees "only N < min" rather than a silent nil.
    func testFunnelBelowMinSamplesKeepsButMeanAbsent() {
        let start = 10_000_000
        let sess = [session(start: start, durSec: 100)]
        let hrs = (0..<100).map { hr(start + $0) }
        let temps = (0..<100).map { skin(start + $0, rawX100: 3400) }  // 100 < minSkinTempSamples
        let f = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps)
        XCTAssertEqual(f.kept, 100)
        XCTAssertGreaterThan(f.minSamples, 100)
        XCTAssertTrue(f.isAbsent, "kept < minSamples → no trusted mean")
    }

    // MARK: - device-family-aware conversion (#938)

    /// A WHOOP 4.0 v24 worn night (raw ~826–860, the reporter's steady worn baseline) produced NO nightly
    /// mean under the old family-blind /100 (raw 826 → 8.3 °C, below the 28 °C worn gate, kept=0). With the
    /// `.whoop4` scale those same raw values land ~33 °C and the night is kept — the fix.
    func testWhoop4WornNightProducesMeanUnderFamilyAwareScale() throws {
        let start = 11_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        // Steady worn 4.0 raw ~840 — impossible 8.4 °C under /100, plausible ~33.7 °C under the 4.0 map.
        let temps = (0..<600).map { SkinTempSample(ts: start + $0, raw: 840) }
        // Old behaviour (family-blind /100 == `.whoop5`): dropped, no mean.
        XCTAssertNil(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop5))
        // Fixed behaviour (`.whoop4`): a trusted nightly mean in the plausible worn band.
        let mean = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop4))
        XCTAssertGreaterThan(mean, 28.0)
        XCTAssertLessThan(mean, 42.0)
    }

    /// A 5/MG worn night is byte-identical whether `family` is defaulted or passed explicitly — the fix
    /// changes nothing for the proven centidegree path.
    func testWhoop5NightUnchangedByFamilyParameter() throws {
        let start = 12_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { skin(start + $0, rawX100: 3400) }  // 34 °C centidegrees
        let defaulted = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps))
        let explicit = try XCTUnwrap(AnalyticsEngine.wornNightlySkinTempC(sess, hr: hrs, skinTemp: temps, family: .whoop5))
        XCTAssertEqual(defaulted, 34.0, accuracy: 1e-9)
        XCTAssertEqual(defaulted, explicit)
    }

    /// The funnel diagnostic reports the SAME family-aware outcome: a worn 4.0 night is kept under `.whoop4`
    /// but all-out-of-range (dropped) under the family-blind `.whoop5` scale.
    func testFunnelFamilyAwareAttribution() {
        let start = 13_000_000
        let sess = [session(start: start, durSec: 600)]
        let hrs = (0..<600).map { hr(start + $0) }
        let temps = (0..<600).map { SkinTempSample(ts: start + $0, raw: 840) }
        let w5 = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps, family: .whoop5)
        XCTAssertEqual(w5.droppedOutOfRange, 600, "under /100 the 4.0 worn raw reads ~8 °C, all out of range")
        XCTAssertTrue(w5.isAbsent)
        let w4 = AnalyticsEngine.skinTempFunnel(sess, hr: hrs, skinTemp: temps, family: .whoop4)
        XCTAssertEqual(w4.kept, 600)
        XCTAssertFalse(w4.isAbsent)
    }

    // MARK: - seed → deviation (skin_temp baseline)

    private let skinCfg = Baselines.metricCfg["skin_temp"]!

    func testColdStartBelowSeedBaselineNotUsable() {
        // 3 nightly means (< minNightsSeed = 4): still CALIBRATING → skinTempDevC stays nil.
        let nights: [Double?] = [33.5, 33.6, 33.4]
        XCTAssertFalse(Baselines.foldHistory(nights, cfg: skinCfg).usable)
    }

    func testAtSeedUsableElevationShowsPositiveDeviation() {
        // 4 baseline nights ~33.5 °C; a +0.8 °C night surfaces as a clearly positive deviation —
        // the signal the illness watch reads as its skin-temp flag (fires at ≥ +0.6 °C).
        let nights: [Double?] = [33.5, 33.4, 33.6, 33.5]
        let base = Baselines.foldHistory(nights, cfg: skinCfg)
        XCTAssertTrue(base.usable, "4 valid nights must seed a usable skin-temp baseline")
        let dev = Baselines.deviation(34.3, state: base).delta
        XCTAssertGreaterThan(dev, 0.5, "a +0.8 °C night must read as a clear positive deviation")
    }
}
