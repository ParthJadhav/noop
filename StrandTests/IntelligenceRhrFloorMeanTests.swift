import XCTest
@testable import Strand

/// Pins the RHR floor-vs-mean strap-log line (#691). The recurring "NOOP's resting HR reads LOWER than
/// my sleeping-HR app" reports are NOT a bug: NOOP's `restingHr` is the WHOOP-style FLOOR (the lowest
/// sustained 5-min in-bed level), whereas a "sleeping HR" app reports the night MEAN over the whole
/// asleep span. The mean always sits at-or-above the floor, so NOOP looking lower is by design. The
/// engine now logs BOTH per scored night so a report carries the proof. `rhrFloorMeanLogLine` is the
/// pure formatter the loop calls; it's tested directly (no store). Mirrors the Android
/// `IntelligenceRhrFloorMeanTest` so the two platforms log byte-identical lines.
@MainActor
final class IntelligenceRhrFloorMeanTests: XCTestCase {

    private typealias IE = IntelligenceEngine

    func testFloorBelowMean_theReportedDiscrepancy() {
        // The exact shape of the reports: an in-bed stretch that dips to a 48 bpm floor but averages 55.
        // Both numbers ship so a "NOOP is lower than my other app" report is explainable from the log.
        let bpms = [48, 50, 52, 55, 58, 60, 62]   // mean = 55.0 → "55"
        let line = IE.rhrFloorMeanLogLine(day: "2026-06-12", floor: 48, inBedBpms: bpms)
        XCTAssertEqual(line,
            "rhr day=2026-06-12 floor=48 nightMean=55 inBedSamples=7 "
            + "(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)")
    }

    func testMeanRoundsToNearest() {
        // 50,51,52,54 → 207/4 = 51.75 → rounds to 52 (banker-free .rounded()), matching Kotlin Math.round.
        let line = IE.rhrFloorMeanLogLine(day: "2026-06-13", floor: 50, inBedBpms: [50, 51, 52, 54])
        XCTAssertTrue(line.contains("floor=50 nightMean=52 inBedSamples=4"), line)
    }

    func testEmptyInBed_meanIsNil() {
        // A banked floor but no HR sample fell inside a matched session (edge): mean reads "nil", not 0,
        // and the line is still emitted so the night stays visible in the log.
        let line = IE.rhrFloorMeanLogLine(day: "2026-06-12", floor: 47, inBedBpms: [])
        XCTAssertEqual(line,
            "rhr day=2026-06-12 floor=47 nightMean=nil inBedSamples=0 "
            + "(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)")
    }

    func testFloorNeverExceedsMean_byConstruction() {
        // Sanity on the framing itself: across any in-bed set the floor (a min over the same span) is
        // <= the mean, so NOOP's RHR can only read at-or-below a sleeping-HR-app's night mean.
        let bpms = [44, 46, 49, 53, 57, 61]
        let mean = Double(bpms.reduce(0, +)) / Double(bpms.count)
        XCTAssertLessThanOrEqual(Double(bpms.min()!), mean)
    }

    func testLineCarriesNoEmDash() {
        // House style: never an em-dash in shared text.
        let line = IE.rhrFloorMeanLogLine(day: "2026-06-12", floor: 48, inBedBpms: [48, 60])
        XCTAssertFalse(line.contains("—"))
    }
}
