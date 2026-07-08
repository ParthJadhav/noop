import XCTest
@testable import StrandAnalytics

/// The per-mode day/night capture accumulator (#965). Each active mode's "K of N" must reflect the DISTINCT
/// days that mode actually produced a trace on, read off the shareable strap log, so Sleep, Battery and
/// Steps accumulate INDEPENDENTLY rather than sharing one elapsed-clock number.
final class CaptureAccumulatorTests: XCTestCase {

    // A three-day capture in the exact shape the live emitters write (verbatim from a real 5/MG report).
    // Sleep + Steps carry `day=`; Battery banks `bank soc=... t=<unix>s` samples; universal `dayOwner day=`.
    // 2026-06-30, 07-01, 07-02 are three distinct nights/days; the three battery stamps below are all inside
    // 2026-07-02 UTC (02:00 / 03:00 / 04:00), so at offset 0 they fold to ONE day (the accumulator counts
    // distinct days, not samples).
    private let report = """
    [sleep] gate run=0 spanS=1163 DROPPED gate=minSleepMin spanMin=19 minSleepMin=60
    sleep day=2026-07-02 totalSleepMin=131 matched=3 source=computed
    sleep day=2026-07-01 totalSleepMin=331 matched=1 source=computed
    sleep day=2026-06-30 totalSleepMin=381 matched=1 source=computed
    [steps] stepsRaw day=2026-07-02 counterSamples=29248 firstCounter=65046 lastCounter=5336
    [steps] stepsRaw day=2026-07-01 counterSamples=1000
    [battery] bank soc=26.0 t=1782957600s
    [battery] bank soc=25.0 t=1782961200s
    [battery] bank soc=24.0 t=1782964800s
    [universal] dayOwner day=2026-07-02 readId=my-whoop writeActiveId=my-whoop hrRows=120 provenance=measured
    [universal] dayOwner day=2026-07-01 readId=my-whoop writeActiveId=my-whoop hrRows=120 provenance=measured
    """

    /// Sleep counts three DISTINCT nights from its `sleep day=` lines (the DROPPED gate line carries no day
    /// key, so it does not inflate the count; the three dated lines do).
    func testSleepCountsDistinctNights() {
        XCTAssertEqual(CaptureAccumulator.capturedDays(domain: .sleep, reportText: report, tzOffsetSeconds: 0), 3)
    }

    /// Steps counts two distinct days from its `stepsRaw day=` lines.
    func testStepsCountsDistinctDays() {
        XCTAssertEqual(CaptureAccumulator.capturedDays(domain: .steps, reportText: report, tzOffsetSeconds: 0), 2)
    }

    /// Battery folds its `t=<unix>s` samples to a local day: three stamps inside one UTC day => 1 day at
    /// offset 0. This is the #965 heart: the counter reflects DISTINCT captured days, never the sample count.
    func testBatteryFoldsEpochSamplesToOneDay() {
        XCTAssertEqual(CaptureAccumulator.capturedDays(domain: .battery, reportText: report, tzOffsetSeconds: 0), 1)
    }

    /// The universal dayOwner line accumulates once per scored day (two here).
    func testUniversalCountsScoredDays() {
        XCTAssertEqual(CaptureAccumulator.capturedDays(domain: .universal, reportText: report, tzOffsetSeconds: 0), 2)
    }

    /// Each mode accumulates INDEPENDENTLY: sleep=3, steps=2, battery=1 off the SAME log, so the three rows
    /// diverge instead of every guided row sharing one number (the #965 "stuck at 1 of 3" regression).
    func testModesAccumulateIndependently() {
        XCTAssertEqual(CaptureAccumulator.capturedDays(domain: .sleep, reportText: report, tzOffsetSeconds: 0), 3)
        XCTAssertEqual(CaptureAccumulator.capturedDays(domain: .steps, reportText: report, tzOffsetSeconds: 0), 2)
        XCTAssertEqual(CaptureAccumulator.capturedDays(domain: .battery, reportText: report, tzOffsetSeconds: 0), 1)
    }

    /// A dead-trace mode (active but no line landed) reads 0, never a fabricated number.
    func testDeadTraceIsZero() {
        let onlyBattery = "[battery] bank soc=50.0 t=1782957600s"
        XCTAssertEqual(CaptureAccumulator.capturedDays(domain: .sleep, reportText: onlyBattery, tzOffsetSeconds: 0), 0)
        XCTAssertEqual(CaptureAccumulator.capturedDays(domain: .steps, reportText: onlyBattery, tzOffsetSeconds: 0), 0)
    }

    /// A domain with no registered day-marker (no day-bearing trace) accumulates 0 rather than mis-counting.
    func testUnmarkedDomainIsZero() {
        XCTAssertEqual(CaptureAccumulator.capturedDays(domain: .connection, reportText: report, tzOffsetSeconds: 0), 0)
    }

    /// A `day=` on some OTHER mode's line does not leak into an unrelated mode's count: the token scoping
    /// keeps each mode counting only its own lines.
    func testDayKeyDoesNotLeakAcrossModes() {
        // A workouts line carrying a day= must not count toward sleep.
        let cross = "[workouts] autoDetect day=2026-07-05 windows=1\nsleep day=2026-07-02 totalSleepMin=100 matched=1 source=computed"
        XCTAssertEqual(CaptureAccumulator.capturedDays(domain: .sleep, reportText: cross, tzOffsetSeconds: 0), 1)
    }

    /// A west-of-UTC offset re-buckets a battery stamp near the UTC-midnight boundary onto the local day, so
    /// the fold uses the SAME local-day convention as AnalyticsEngine.dayString (the day keys agree).
    func testBatteryLocalDayFold() {
        // 1782957600 = 2026-07-02 02:00 UTC. At UTC-9h (-32400s) it is 2026-07-01 17:00 local => prior day.
        let one = "[battery] bank soc=40.0 t=1782957600s"
        XCTAssertEqual(CaptureAccumulator.capturedDayKeys(domain: .battery, reportText: one, tzOffsetSeconds: 0),
                       ["2026-07-02"])
        XCTAssertEqual(CaptureAccumulator.capturedDayKeys(domain: .battery, reportText: one, tzOffsetSeconds: -32400),
                       ["2026-07-01"])
    }
}
