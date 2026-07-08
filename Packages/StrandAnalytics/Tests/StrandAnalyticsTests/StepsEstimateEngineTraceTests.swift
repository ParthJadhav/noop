import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The Steps test mode's two pure traces. Pins the lines a fixture produces AND proves the trace can never
/// diverge from the production numbers: the 5/MG raw-counter trace's scaledSteps equals
/// AnalyticsEngine.analyzeDay(...).daily.steps EXACTLY (same wrap-aware sum, same maxStepDelta gate, same
/// ticks-per-step scaling), and the WHOOP-4 calibration trace reuses StepsEstimateEngine.calibrate verbatim.
/// Twin of the Android StepsEstimateEngineTraceTest. No em-dashes.
final class StepsEstimateEngineTraceTests: XCTestCase {

    private let profile = UserProfile()

    // A timestamp safely inside UTC day 2026-01-02 (2026-01-02T12:00:00Z = 1767355200).
    private let dayUtc = "2026-01-02"
    private let noonUtc = 1_767_355_200

    private func step(_ tsOffsetSec: Int, _ counter: Int) -> StepSample {
        StepSample(ts: noonUtc + tsOffsetSec, counter: counter)
    }

    // MARK: - 5/MG raw-counter trace

    func testRawTotalEqualsAnalyzeDaySteps() {
        // counters 100 -> 150 -> 220 => deltas 50 + 70 = 120; analyzeDay returns the same.
        let samples = [step(0, 100), step(60, 150), step(120, 220)]
        let production = AnalyticsEngine.analyzeDay(day: dayUtc, steps: samples, profile: profile).daily.steps
        XCTAssertEqual(production, 120)
        let lines = StepsEstimateEngine.rawCounterTrace(
            daySteps: samples, dayKey: dayUtc, tzOffsetSeconds: 0, ticksPerStep: profile.stepTicksPerStep)
        let totalLine = lines.first { $0.hasPrefix("stepsRaw total ") }
        XCTAssertNotNil(totalLine)
        // The trace's scaledSteps must equal the day's production steps total EXACTLY.
        XCTAssertTrue(totalLine!.contains("scaledSteps=\(production!)"),
                      "trace scaledSteps must equal analyzeDay steps, got \(totalLine!)")
        XCTAssertTrue(totalLine!.contains("rawTicks=120"))
    }

    func testWrapAwareDeltaIsReportedAndCounted() {
        // 65500 -> 30 wraps: (30 - 65500) & 0xFFFF = 66; 30 -> 90 = 60. Both kept (< 512).
        let samples = [step(0, 65_500), step(60, 30), step(120, 90)]
        let production = AnalyticsEngine.analyzeDay(day: dayUtc, steps: samples, profile: profile).daily.steps
        XCTAssertEqual(production, 66 + 60)
        let lines = StepsEstimateEngine.rawCounterTrace(
            daySteps: samples, dayKey: dayUtc, tzOffsetSeconds: 0, ticksPerStep: profile.stepTicksPerStep)
        XCTAssertTrue(lines.contains { $0.contains("stepsRaw deltas kept=2 dropped=0") })
        XCTAssertTrue(lines.first { $0.hasPrefix("stepsRaw total ") }!.contains("scaledSteps=\(production!)"))
        XCTAssertFalse(lines.contains { $0.contains("\u{2014}") })
    }

    func testDroppedDeltaIsCountedAndExcluded() {
        // 100 -> 150 (kept, 50) -> 1000 (delta 850 >= 512, DROPPED as a sync-gap) -> 1050 (kept, 50).
        let samples = [step(0, 100), step(60, 150), step(120, 1_000), step(180, 1_050)]
        let production = AnalyticsEngine.analyzeDay(day: dayUtc, steps: samples, profile: profile).daily.steps
        XCTAssertEqual(production, 100)   // 50 + 50, the 850 jump excluded
        let lines = StepsEstimateEngine.rawCounterTrace(
            daySteps: samples, dayKey: dayUtc, tzOffsetSeconds: 0, ticksPerStep: profile.stepTicksPerStep)
        XCTAssertTrue(lines.contains { $0.contains("stepsRaw deltas kept=2 dropped=1") })
        XCTAssertTrue(lines.first { $0.hasPrefix("stepsRaw total ") }!.contains("scaledSteps=\(production!)"))
    }

    func testTicksPerStepScalingMatchesAnalyzeDay() {
        // A ticks-per-step of 2.0 halves the raw ticks; the trace must match analyzeDay's scaled value.
        let scaledProfile = UserProfile(stepTicksPerStep: 2.0)
        let samples = [step(0, 0), step(60, 100), step(120, 200)]   // raw ticks = 200
        let production = AnalyticsEngine.analyzeDay(day: dayUtc, steps: samples, profile: scaledProfile).daily.steps
        let lines = StepsEstimateEngine.rawCounterTrace(
            daySteps: samples, dayKey: dayUtc, tzOffsetSeconds: 0, ticksPerStep: scaledProfile.stepTicksPerStep)
        XCTAssertTrue(lines.first { $0.hasPrefix("stepsRaw total ") }!.contains("scaledSteps=\(production!)"))
    }

    func testTinyTotalRoundingToZeroRendersNoneNotZero() {
        // L7: a rawTotal that scales below 0.5 (here 1 tick / ticksPerStep 3.0 = 0.33 -> rounds to 0) makes
        // production analyzeDay return NIL (scaled>0 ? scaled : nil). The trace must read "scaledSteps=none",
        // not "scaledSteps=0", so it matches the missing headline instead of implying a real zero measurement.
        let tinyProfile = UserProfile(stepTicksPerStep: 3.0)
        let samples = [step(0, 100), step(60, 101)]   // one kept delta of 1 tick
        let production = AnalyticsEngine.analyzeDay(day: dayUtc, steps: samples, profile: tinyProfile).daily.steps
        XCTAssertNil(production, "a sub-0.5 scaled total is nil in production")
        let lines = StepsEstimateEngine.rawCounterTrace(
            daySteps: samples, dayKey: dayUtc, tzOffsetSeconds: 0, ticksPerStep: tinyProfile.stepTicksPerStep)
        let totalLine = lines.first { $0.hasPrefix("stepsRaw total ") }!
        XCTAssertTrue(totalLine.contains("rawTicks=1"))
        XCTAssertTrue(totalLine.contains("scaledSteps=none"), "got \(totalLine)")
        XCTAssertFalse(totalLine.contains("scaledSteps=0"))
    }

    func testFewerThanTwoSamplesReportsNoDelta() {
        let lines = StepsEstimateEngine.rawCounterTrace(
            daySteps: [step(0, 100)], dayKey: dayUtc, tzOffsetSeconds: 0, ticksPerStep: 1.0)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("counterSamples=1"))
        XCTAssertTrue(lines[0].contains("need >=2"))
    }

    func testEmptyCounterReportsNoRawCounterNotBroken() {
        // #810: a WHOOP 4.0 sends NO raw step counter, so daySteps is empty for it. The trace must say so
        // honestly (the device is motion-estimated), NOT emit the "counterSamples=0 ... need >=2" line that
        // read as broken. A 5/MG never hits this branch (it always banks counter rows). Twin of the Android
        // emptyCounterReportsNoRawCounterNotBroken.
        let lines = StepsEstimateEngine.rawCounterTrace(
            daySteps: [], dayKey: dayUtc, tzOffsetSeconds: 0, ticksPerStep: 1.0)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("counterSamples=0"))
        XCTAssertTrue(lines[0].contains("noRawCounter"))
        XCTAssertTrue(lines[0].contains("motion-estimated"))
        XCTAssertFalse(lines[0].contains("need >=2"))  // not the misleading "broken" line
        XCTAssertFalse(lines[0].contains("\u{2014}"))   // no em-dash
    }

    func testEmptyAfterDayFilterAlsoReportsNoRawCounter() {
        // daySteps has rows, but none fall on the requested day (e.g. all on a neighbouring day). After the
        // local-day filter the sorted list is empty, so the same honest noRawCounter line is emitted rather
        // than a broken-looking counterSamples=0 ... need >=2. Twin of the Android
        // emptyAfterDayFilterAlsoReportsNoRawCounter.
        let otherDay = [step(2 * 86_400, 100), step(2 * 86_400 + 60, 150)]
        let lines = StepsEstimateEngine.rawCounterTrace(
            daySteps: otherDay, dayKey: dayUtc, tzOffsetSeconds: 0, ticksPerStep: 1.0)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("noRawCounter"))
    }

    // MARK: - WHOOP-4 calibration trace

    func testCalibrationTraceReusesCalibrateVerbatim() {
        let points = [
            StepsEstimateEngine.CalibrationPoint(motion: 100, steps: 1_000),
            StepsEstimateEngine.CalibrationPoint(motion: 200, steps: 2_000),
            StepsEstimateEngine.CalibrationPoint(motion: 300, steps: 3_000),
        ]
        let cal = StepsEstimateEngine.calibrate(points)!
        let lines = StepsEstimateEngine.calibrationTrace(points: points)
        let fitLine = lines.first { $0.hasPrefix("stepsCal fit ") }
        XCTAssertNotNil(fitLine)
        // The reported coefficient must equal calibrate(...)'s, rounded to 2dp.
        let k2 = (cal.coefficient * 100).rounded() / 100
        XCTAssertTrue(fitLine!.contains("k=\(k2)"), fitLine!)
        XCTAssertTrue(fitLine!.contains("sampleDays=\(cal.sampleDays)"))
        XCTAssertTrue(fitLine!.contains("manual=false"))
        // One point line per usable day.
        XCTAssertEqual(lines.filter { $0.hasPrefix("stepsCal point ") }.count, 3)
        XCTAssertFalse(lines.contains { $0.contains("\u{2014}") })
    }

    func testCalibrationTraceNamesWithheldReason() {
        // Two usable days < minCalibrationDays (3), no manual override: withheld with needsMoreDays.
        let points = [
            StepsEstimateEngine.CalibrationPoint(motion: 100, steps: 1_000),
            StepsEstimateEngine.CalibrationPoint(motion: 200, steps: 2_000),
        ]
        XCTAssertNil(StepsEstimateEngine.calibrate(points))
        let lines = StepsEstimateEngine.calibrationTrace(points: points)
        let withheld = lines.first { $0.contains("stepsCal withheld ") }
        XCTAssertNotNil(withheld)
        XCTAssertTrue(withheld!.contains("reason=needsMoreDays"))
        XCTAssertTrue(withheld!.contains("have=2"))
        XCTAssertTrue(withheld!.contains("need=3"))
    }

    func testManualOverrideTraceReportsManual() {
        let points = [StepsEstimateEngine.CalibrationPoint(motion: 100, steps: 1_000)]
        let lines = StepsEstimateEngine.calibrationTrace(points: points, manualOverride: 9.5)
        let fitLine = lines.first { $0.hasPrefix("stepsCal fit ") }
        XCTAssertNotNil(fitLine)
        XCTAssertTrue(fitLine!.contains("manual=true"))
        XCTAssertTrue(fitLine!.contains("k=9.5"))
    }

    // MARK: - Readout parsers

    func testStepsReadoutParsesScaledSteps() {
        let tail = ["[steps] stepsRaw total rawTicks=120 ticksPerStep=1.0 scaledSteps=120 (steps_est for the day)"]
        XCTAssertEqual(StepsReadout.stepsToday(taggedTail: tail), 120)
    }

    func testStepsReadoutParsesEstimateLine() {
        let tail = ["[steps] stepsEst day=2026-01-02 steps=8421 motion=4123.5 (motion-volume estimate)"]
        XCTAssertEqual(StepsReadout.stepsToday(taggedTail: tail), 8421)
    }

    func testCalibrationStateReadoutParsesFitAndWithheld() {
        let fit = ["[steps] stepsCal fit k=10.0 sampleDays=5 confidence=0.8 manual=false (k = motion-weighted median of steps/motion)"]
        XCTAssertEqual(StepsReadout.calibrationState(taggedTail: fit), "k=10.0 sampleDays=5 confidence=0.8 manual=false")
        let withheld = ["[steps] stepsCal withheld reason=needsMoreDays have=2 need=3 (no usable auto-fit and no manual k)"]
        XCTAssertEqual(StepsReadout.calibrationState(taggedTail: withheld), "not calibrated (needsMoreDays have=2 need=3)")
    }
}
