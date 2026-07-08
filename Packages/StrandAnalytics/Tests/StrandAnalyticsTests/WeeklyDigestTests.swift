import XCTest
@testable import StrandAnalytics

final class WeeklyDigestTests: XCTestCase {

    // MARK: - Pure week math

    func testMondayOfWeek() {
        // 2026-06-13 is a Saturday → its Monday is 2026-06-08.
        XCTAssertEqual(WeeklyDigestEngine.mondayOfWeek(containing: "2026-06-13"), "2026-06-08")
        // 2026-06-08 is itself a Monday → unchanged.
        XCTAssertEqual(WeeklyDigestEngine.mondayOfWeek(containing: "2026-06-08"), "2026-06-08")
        // 2026-06-14 is a Sunday → still the same Monday.
        XCTAssertEqual(WeeklyDigestEngine.mondayOfWeek(containing: "2026-06-14"), "2026-06-08")
    }

    func testWeekdaySakamoto() {
        // 0=Sun … 6=Sat. 2026-06-08 = Monday(1), 2026-06-13 = Saturday(6), 2026-06-14 = Sunday(0).
        XCTAssertEqual(WeeklyDigestEngine.weekday(2026, 6, 8), 1)
        XCTAssertEqual(WeeklyDigestEngine.weekday(2026, 6, 13), 6)
        XCTAssertEqual(WeeklyDigestEngine.weekday(2026, 6, 14), 0)
        // A classic anchor: 2000-01-01 was a Saturday.
        XCTAssertEqual(WeeklyDigestEngine.weekday(2000, 1, 1), 6)
    }

    func testAddDaysCrossesMonthAndYear() {
        XCTAssertEqual(WeeklyDigestEngine.addDays("2026-06-08", -1), "2026-06-07")
        XCTAssertEqual(WeeklyDigestEngine.addDays("2026-06-08", -7), "2026-06-01")
        XCTAssertEqual(WeeklyDigestEngine.addDays("2026-06-08", -8), "2026-05-31")  // month rollback
        XCTAssertEqual(WeeklyDigestEngine.addDays("2026-01-01", -1), "2025-12-31")  // year rollback
        XCTAssertEqual(WeeklyDigestEngine.addDays("2026-06-08", 6), "2026-06-14")
    }

    func testAddDaysLeapYear() {
        // 2024 is a leap year → Feb 29 exists.
        XCTAssertEqual(WeeklyDigestEngine.addDays("2024-02-28", 1), "2024-02-29")
        XCTAssertEqual(WeeklyDigestEngine.addDays("2024-02-29", 1), "2024-03-01")
        // 2026 is not → Feb has 28 days.
        XCTAssertEqual(WeeklyDigestEngine.addDays("2026-02-28", 1), "2026-03-01")
        XCTAssertNil(WeeklyDigestEngine.parseYMD("2026-02-29"))  // not a real date
    }

    func testBadAnchorGivesEmptyDigest() {
        let d = WeeklyDigestEngine.build(byMetric: [:], anchorDay: "not-a-date")
        XCTAssertTrue(d.isEmpty)
        XCTAssertEqual(d.daysWithData, 0)
        XCTAssertEqual(d.metrics.count, WeeklyMetric.allCases.count)
        XCTAssertEqual(d.balance, .insufficient)
        XCTAssertTrue(d.focalPoints.isEmpty)
    }

    // MARK: - Window split (golden fixture)

    /// Build a fixture where Charge is exactly 70 every day THIS week (Mon 2026-06-08 →
    /// Sun 2026-06-14) and exactly 60 every day LAST week. Anchor = Saturday of this week.
    func testWeekSplitAndWoW() {
        var charge: [String: Double] = [:]
        // This week: Mon..Sun = 70.
        for d in 8...14 { charge[String(format: "2026-06-%02d", d)] = 70 }
        // Last week: Mon 2026-06-01 .. Sun 2026-06-07 = 60.
        for d in 1...7 { charge[String(format: "2026-06-%02d", d)] = 60 }

        let digest = WeeklyDigestEngine.build(byMetric: [.charge: charge], anchorDay: "2026-06-13")
        XCTAssertEqual(digest.weekStart, "2026-06-08")
        XCTAssertEqual(digest.weekEnd, "2026-06-14")
        XCTAssertEqual(digest.daysWithData, 7)

        let c = digest.summary(.charge)!
        XCTAssertEqual(c.thisWeek.n, 7)
        XCTAssertEqual(c.thisWeek.mean, 70.0, accuracy: 1e-9)
        XCTAssertEqual(c.weekOverWeek.previous.n, 7)
        XCTAssertEqual(c.weekOverWeek.previous.mean, 60.0, accuracy: 1e-9)
        XCTAssertEqual(c.wowDelta, 10.0, accuracy: 1e-9)            // 70 − 60
        XCTAssertEqual(c.weekOverWeek.pctChange!, 100.0 / 6.0, accuracy: 1e-6)  // 10/60
        XCTAssertEqual(c.wowGoodness, 1)                           // Charge up → good
    }

    func testDaysOutsideTheWeekAreIgnored() {
        var charge: [String: Double] = [:]
        for d in 8...14 { charge[String(format: "2026-06-%02d", d)] = 70 }
        charge["2026-06-15"] = 999   // next Monday — must NOT be in this week
        charge["2026-06-07"] = 999   // last Sunday — must NOT be in this week
        let c = WeeklyDigestEngine.build(byMetric: [.charge: charge], anchorDay: "2026-06-10").summary(.charge)!
        XCTAssertEqual(c.thisWeek.n, 7)
        XCTAssertEqual(c.thisWeek.max, 70.0, accuracy: 1e-9)   // the 999s were excluded
    }

    // MARK: - vs-baseline

    func testVsBaselineUsesFourPriorWeeks() {
        var hrv: [String: Double] = [:]
        // This week (Mon 06-08 .. Sun 06-14): mean 60.
        for d in 8...14 { hrv[String(format: "2026-06-%02d", d)] = 60 }
        // Last week (06-01 .. 06-07): mean 55 (not part of baseline).
        for d in 1...7 { hrv[String(format: "2026-06-%02d", d)] = 55 }
        // Baseline = the 4 complete weeks BEFORE last week: 2026-05-04 .. 2026-05-31, all 50.
        for day in WeeklyDigestTests.daysBetween("2026-05-04", "2026-05-31") { hrv[day] = 50 }

        let h = WeeklyDigestEngine.build(byMetric: [.hrv: hrv], anchorDay: "2026-06-13").summary(.hrv)!
        XCTAssertEqual(h.baselineMean!, 50.0, accuracy: 1e-9)
        XCTAssertEqual(h.vsBaseline!, 10.0, accuracy: 1e-9)   // 60 − 50
    }

    // MARK: - Sleep consistency

    func testSleepConsistencyIsSDOfRest() {
        // Rest values 80,82,84,86,88,90,92 → sample SD ≈ 4.3205.
        var rest: [String: Double] = [:]
        let vals = [80.0, 82, 84, 86, 88, 90, 92]
        for (i, v) in vals.enumerated() { rest[String(format: "2026-06-%02d", 8 + i)] = v }
        let d = WeeklyDigestEngine.build(byMetric: [.rest: rest], anchorDay: "2026-06-10")
        XCTAssertNotNil(d.sleepConsistencySD)
        XCTAssertEqual(d.sleepConsistencySD!, 4.320493798938574, accuracy: 1e-9)
    }

    func testSleepConsistencyNilWithOneNight() {
        let rest: [String: Double] = ["2026-06-08": 85]
        let d = WeeklyDigestEngine.build(byMetric: [.rest: rest], anchorDay: "2026-06-10")
        XCTAssertNil(d.sleepConsistencySD)   // < 2 nights → no consistency read
    }

    // MARK: - Balance read

    func testBalanceOverreaching() {
        // Effort mean 80, Charge mean 50 → gap +30 > band → overreaching.
        var effort: [String: Double] = [:], charge: [String: Double] = [:]
        for d in 8...14 { effort[String(format: "2026-06-%02d", d)] = 80; charge[String(format: "2026-06-%02d", d)] = 50 }
        let d = WeeklyDigestEngine.build(byMetric: [.effort: effort, .charge: charge], anchorDay: "2026-06-10")
        XCTAssertEqual(d.balance, .overreaching)
    }

    func testBalanceUnderloaded() {
        var effort: [String: Double] = [:], charge: [String: Double] = [:]
        for d in 8...14 { effort[String(format: "2026-06-%02d", d)] = 40; charge[String(format: "2026-06-%02d", d)] = 75 }
        let d = WeeklyDigestEngine.build(byMetric: [.effort: effort, .charge: charge], anchorDay: "2026-06-10")
        XCTAssertEqual(d.balance, .underloaded)
    }

    func testBalanceBalanced() {
        var effort: [String: Double] = [:], charge: [String: Double] = [:]
        for d in 8...14 { effort[String(format: "2026-06-%02d", d)] = 55; charge[String(format: "2026-06-%02d", d)] = 60 }
        let d = WeeklyDigestEngine.build(byMetric: [.effort: effort, .charge: charge], anchorDay: "2026-06-10")
        XCTAssertEqual(d.balance, .balanced)
    }

    func testBalanceInsufficientWithTooFewDays() {
        // Only 2 days each side → below minDaysForFocus (3).
        var effort: [String: Double] = [:], charge: [String: Double] = [:]
        for d in 8...9 { effort[String(format: "2026-06-%02d", d)] = 80; charge[String(format: "2026-06-%02d", d)] = 50 }
        let d = WeeklyDigestEngine.build(byMetric: [.effort: effort, .charge: charge], anchorDay: "2026-06-10")
        XCTAssertEqual(d.balance, .insufficient)
    }

    // MARK: - Focal points

    func testFocalPointSurfacesBiggestMover() {
        // Charge up big this week, last week flat-low; both weeks fully populated.
        var charge: [String: Double] = [:]
        for d in 8...14 { charge[String(format: "2026-06-%02d", d)] = 80 }  // this week
        for d in 1...7  { charge[String(format: "2026-06-%02d", d)] = 55 }  // last week
        let d = WeeklyDigestEngine.build(byMetric: [.charge: charge], anchorDay: "2026-06-13")
        XCTAssertFalse(d.focalPoints.isEmpty)
        let top = d.focalPoints[0]
        XCTAssertTrue(top.contains("Charge"), "Expected Charge in: \(top)")
        XCTAssertTrue(top.contains("up"), "Expected an upward move in: \(top)")
        XCTAssertTrue(top.contains("good sign"), "Charge rising should read positively: \(top)")
    }

    func testRestingHRRiseReadsAsWorthALook() {
        // RHR up week over week → higherIsBetter == false → "worth a look".
        var rhr: [String: Double] = [:]
        for d in 8...14 { rhr[String(format: "2026-06-%02d", d)] = 60 }  // this week
        for d in 1...7  { rhr[String(format: "2026-06-%02d", d)] = 52 }  // last week
        let d = WeeklyDigestEngine.build(byMetric: [.rhr: rhr], anchorDay: "2026-06-13")
        let line = d.focalPoints.first ?? ""
        XCTAssertTrue(line.contains("Resting HR"), "Expected RHR mover: \(line)")
        XCTAssertTrue(line.contains("worth a look"), "RHR rising should read as a caution: \(line)")
    }

    func testSteadyWeekGivesCalmLine() {
        // Identical values both weeks → no mover, balanced → a single steady line.
        var charge: [String: Double] = [:], effort: [String: Double] = [:], rest: [String: Double] = [:]
        for d in 1...14 {
            let key = String(format: "2026-06-%02d", d)
            charge[key] = 65; effort[key] = 63; rest[key] = 84
        }
        let d = WeeklyDigestEngine.build(byMetric: [.charge: charge, .effort: effort, .rest: rest],
                                         anchorDay: "2026-06-13")
        XCTAssertEqual(d.focalPoints.count, 1)
        XCTAssertTrue(d.focalPoints[0].lowercased().contains("steady"),
                      "Expected a steady-week line: \(d.focalPoints[0])")
    }

    func testSparseWeekSaysTooEarlyNotSteady() {
        // Current week has only 2 days, with a big raw drop vs a full previous week — the
        // per-metric chips would show a large %, but 2 days can't anchor a week-over-week
        // trend. The summary must defer ("too early") rather than claim a steady week with
        // nothing moved, which would contradict the chips (#463).
        var charge: [String: Double] = [:]
        for d in 1...7 { charge[String(format: "2026-06-%02d", d)] = 70 }   // last week, full
        charge["2026-06-08"] = 40                                            // this week, day 1
        charge["2026-06-09"] = 40                                            // this week, day 2
        let d = WeeklyDigestEngine.build(byMetric: [.charge: charge], anchorDay: "2026-06-09")
        XCTAssertEqual(d.summary(.charge)!.thisWeek.n, 2)                    // sparse current week
        XCTAssertEqual(d.focalPoints.count, 1)
        let line = d.focalPoints[0]
        XCTAssertTrue(line.contains("too early"), "Sparse week should defer the call: \(line)")
        XCTAssertTrue(line.contains("2 days"), "Should name the day count: \(line)")
        XCTAssertFalse(line.lowercased().contains("steady"),
                       "Must NOT claim a steady week on 2 days: \(line)")
    }

    func testSparsePreviousWeekSaysRoughNotSteady() {
        // The mirror image of the sparse-current case (typical new user in week 2): the
        // CURRENT week has plenty of days, but LAST week only had 2 — movers are gated on
        // previous.n ≥ minDaysForFocus, so nothing surfaces, while the chips show a big raw %
        // off those 2 days. The summary must call the comparison rough rather than claim a
        // steady week with nothing moved (#463, the residual half).
        var charge: [String: Double] = [:]
        charge["2026-06-06"] = 70                                            // last week, day 1
        charge["2026-06-07"] = 74                                            // last week, day 2
        for d in 8...12 { charge[String(format: "2026-06-%02d", d)] = 41 }   // this week, 5 days
        let d = WeeklyDigestEngine.build(byMetric: [.charge: charge], anchorDay: "2026-06-12")
        XCTAssertEqual(d.summary(.charge)!.thisWeek.n, 5)                    // full-enough current week
        XCTAssertEqual(d.summary(.charge)!.weekOverWeek.previous.n, 2)       // sparse previous week
        XCTAssertEqual(d.focalPoints.count, 1)
        let line = d.focalPoints[0]
        XCTAssertTrue(line.contains("Last week"), "Should point at last week: \(line)")
        XCTAssertTrue(line.contains("rough"), "Should call the comparison rough: \(line)")
        XCTAssertTrue(line.contains("2 days"), "Should name the day count: \(line)")
        XCTAssertFalse(line.lowercased().contains("steady"),
                       "Must NOT claim a steady week against 2 days: \(line)")
        XCTAssertFalse(line.contains("too early"),
                       "The current week is fine; the honesty aims at last week: \(line)")
    }

    // MARK: - Rough-comparison flag (chips must not imply confidence on a sparse side)

    func testIsRoughComparisonFlagsSparseSides() {
        // Sparse CURRENT week (2 days) vs full previous → rough.
        var charge: [String: Double] = [:]
        for d in 1...7 { charge[String(format: "2026-06-%02d", d)] = 70 }
        charge["2026-06-08"] = 40; charge["2026-06-09"] = 40
        let sparseCurrent = WeeklyDigestEngine.build(byMetric: [.charge: charge], anchorDay: "2026-06-09")
        XCTAssertTrue(sparseCurrent.summary(.charge)!.isRoughComparison)

        // Sparse PREVIOUS week (2 days) vs full-enough current → rough.
        var rest: [String: Double] = [:]
        rest["2026-06-06"] = 80; rest["2026-06-07"] = 82
        for d in 8...12 { rest[String(format: "2026-06-%02d", d)] = 85 }
        let sparsePrevious = WeeklyDigestEngine.build(byMetric: [.rest: rest], anchorDay: "2026-06-12")
        XCTAssertTrue(sparsePrevious.summary(.rest)!.isRoughComparison)

        // Both weeks fully populated → a real comparison, not rough.
        var hrv: [String: Double] = [:]
        for d in 1...14 { hrv[String(format: "2026-06-%02d", d)] = 60 }
        let full = WeeklyDigestEngine.build(byMetric: [.hrv: hrv], anchorDay: "2026-06-12")
        XCTAssertFalse(full.summary(.hrv)!.isRoughComparison)

        // No previous week at all → there is no comparison to call rough.
        var rhr: [String: Double] = [:]
        rhr["2026-06-08"] = 55; rhr["2026-06-09"] = 56
        let noPrevious = WeeklyDigestEngine.build(byMetric: [.rhr: rhr], anchorDay: "2026-06-09")
        XCTAssertFalse(noPrevious.summary(.rhr)!.isRoughComparison)
    }

    // MARK: - Effort display factor (the #268 scale toggle reaches the prose)

    func testEffortDisplayFactorDefaultIsByteIdentical() {
        // factor 1.0 (and the omitted default) must not change a single character of
        // any focal point — this pins every existing sentence for existing callers.
        var effort: [String: Double] = [:], charge: [String: Double] = [:]
        for d in 8...14 { let k = String(format: "2026-06-%02d", d); effort[k] = 25; charge[k] = 60 }
        for d in 1...7  { let k = String(format: "2026-06-%02d", d); effort[k] = 35; charge[k] = 60 }
        let input: [WeeklyMetric: [String: Double]] = [.effort: effort, .charge: charge]
        let implicitDefault = WeeklyDigestEngine.build(byMetric: input, anchorDay: "2026-06-13")
        let explicitOne = WeeklyDigestEngine.build(byMetric: input, anchorDay: "2026-06-13",
                                                   effortDisplayFactor: 1.0)
        XCTAssertEqual(implicitDefault, explicitOne)
        XCTAssertTrue(implicitDefault.focalPoints[0].contains("(avg 25 vs 35)"),
                      "Stored-scale averages at factor 1.0: \(implicitDefault.focalPoints[0])")
    }

    func testEffortDisplayFactorRescalesEffortAveragesOnly() {
        // Effort mover 25 vs 35 (stored 0–100). On the 0–21 scale (factor 0.21) the prose
        // averages must read 5 vs 7 while the % (scale-invariant) stays 29%.
        var effort: [String: Double] = [:]
        for d in 8...14 { effort[String(format: "2026-06-%02d", d)] = 25 }
        for d in 1...7  { effort[String(format: "2026-06-%02d", d)] = 35 }
        let scaled = WeeklyDigestEngine.build(byMetric: [.effort: effort], anchorDay: "2026-06-13",
                                              effortDisplayFactor: 0.21)
        let line = scaled.focalPoints[0]
        XCTAssertTrue(line.contains("(avg 5 vs 7)"), "0–21 averages expected: \(line)")
        XCTAssertTrue(line.contains("29%"), "Percent change is scale-invariant: \(line)")

        // A non-Effort mover is untouched by the factor.
        var chargeOnly: [String: Double] = [:]
        for d in 8...14 { chargeOnly[String(format: "2026-06-%02d", d)] = 80 }
        for d in 1...7  { chargeOnly[String(format: "2026-06-%02d", d)] = 55 }
        let input: [WeeklyMetric: [String: Double]] = [.charge: chargeOnly]
        let a = WeeklyDigestEngine.build(byMetric: input, anchorDay: "2026-06-13")
        let b = WeeklyDigestEngine.build(byMetric: input, anchorDay: "2026-06-13",
                                         effortDisplayFactor: 0.21)
        XCTAssertEqual(a.focalPoints, b.focalPoints)
        XCTAssertTrue(b.focalPoints[0].contains("(avg 80 vs 55)"), "Charge stays stored-scale: \(b.focalPoints[0])")
    }

    func testEffortDisplayFactorRescalesPtsFallback() {
        // Previous Effort mean is 0 → pctChange is nil → the "pts" fallback renders, and it
        // must be in display units too (10 stored pts × 0.21 = 2.1 pts on the 0–21 scale).
        var effort: [String: Double] = [:]
        for d in 8...14 { effort[String(format: "2026-06-%02d", d)] = 10 }
        for d in 1...7  { effort[String(format: "2026-06-%02d", d)] = 0 }
        let d = WeeklyDigestEngine.build(byMetric: [.effort: effort], anchorDay: "2026-06-13",
                                         effortDisplayFactor: 0.21)
        let line = d.focalPoints[0]
        XCTAssertTrue(line.contains("2.1 pts"), "pts fallback should be display-scaled: \(line)")
        XCTAssertTrue(line.contains("(avg 2 vs 0)"), "Averages display-scaled: \(line)")
    }

    func testFocalPointsCappedAtTwo() {
        // Several big movers + a non-trivial balance → still ≤ 2 lines.
        var charge: [String: Double] = [:], effort: [String: Double] = [:], hrv: [String: Double] = [:]
        for d in 8...14 { let k = String(format: "2026-06-%02d", d); charge[k] = 85; effort[k] = 30; hrv[k] = 75 }
        for d in 1...7  { let k = String(format: "2026-06-%02d", d); charge[k] = 50; effort[k] = 70; hrv[k] = 45 }
        let d = WeeklyDigestEngine.build(byMetric: [.charge: charge, .effort: effort, .hrv: hrv],
                                         anchorDay: "2026-06-13")
        XCTAssertLessThanOrEqual(d.focalPoints.count, 2)
        XCTAssertGreaterThanOrEqual(d.focalPoints.count, 1)
    }

    // MARK: - Determinism

    func testDeterministicAcrossRuns() {
        var charge: [String: Double] = [:], hrv: [String: Double] = [:]
        for d in 1...14 {
            let k = String(format: "2026-06-%02d", d)
            charge[k] = Double((d * 7) % 40 + 50)
            hrv[k] = Double((d * 13) % 30 + 45)
        }
        let a = WeeklyDigestEngine.build(byMetric: [.charge: charge, .hrv: hrv], anchorDay: "2026-06-13")
        let b = WeeklyDigestEngine.build(byMetric: [.charge: charge, .hrv: hrv], anchorDay: "2026-06-13")
        XCTAssertEqual(a, b)   // same input → byte-identical digest
    }

    // MARK: - Helpers

    /// Inclusive list of "yyyy-MM-dd" days from `start` to `end`, using the engine's own
    /// pure date math (so the fixture and the code agree on the calendar).
    private static func daysBetween(_ start: String, _ end: String) -> [String] {
        var out: [String] = []
        var cur = start
        while cur <= end {
            out.append(cur)
            cur = WeeklyDigestEngine.addDays(cur, 1)
        }
        return out
    }
}
