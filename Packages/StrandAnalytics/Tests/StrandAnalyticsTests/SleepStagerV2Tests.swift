import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Basic coverage for the OPT-IN experimental stager `SleepStagerV2` (V7 Pillar 3b, reimplemented from
/// contributor PR #600). These assert the drop-in CONTRACT — same `stageSession` signature + return shape as
/// V1, segments that tile `[start, end]` with canonical stage labels — and a couple of recipe invariants.
/// They are NOT a fidelity claim against any reference (the recipe's own validation is n=1).
final class SleepStagerV2Tests: XCTestCase {

    // MARK: - fixtures

    /// A still gravity stream (constant orientation) at 1 Hz — the quiescent sleep floor.
    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    /// A low, slowly-varying HR stream at 1 Hz (sleep-band HR).
    private func sleepHR(start: Int, durationS: Int, base: Int = 52) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: base + ($0 / 60) % 3) }
    }

    /// A regular R-R stream at ~1 Hz (steady ~1000 ms beats with a small respiratory sinus oscillation).
    private func regularRR(start: Int, durationS: Int) -> [RRInterval] {
        (0..<durationS).map { i -> RRInterval in
            let rsa = Int(40.0 * sin(2.0 * Double.pi * Double(i) / 4.0))  // ~0.25 Hz breathing
            return RRInterval(ts: start + i, rrMs: 1000 + rsa)
        }
    }

    // MARK: - drop-in contract

    func testStagesTileTheWholeSpanContiguously() {
        let start = 1_700_000_000
        let dur = 90 * 60  // 90 min
        let segs = SleepStagerV2.stageSession(
            start: start, end: start + dur,
            grav: stillGravity(start: start, durationS: dur),
            hr: sleepHR(start: start, durationS: dur),
            rr: regularRR(start: start, durationS: dur),
            resp: [])

        XCTAssertFalse(segs.isEmpty, "a covered window must produce at least one segment")
        // First segment starts exactly at `start`, last ends exactly at `end`, and segments are contiguous.
        XCTAssertEqual(segs.first?.start, start)
        XCTAssertEqual(segs.last?.end, start + dur)
        for i in 1..<segs.count {
            XCTAssertEqual(segs[i].start, segs[i - 1].end, "segments must tile with no gap/overlap")
            XCTAssertGreaterThan(segs[i].end, segs[i].start, "each segment is non-empty")
        }
    }

    func testOnlyCanonicalStageLabels() {
        let start = 1_700_000_000
        let dur = 80 * 60
        let segs = SleepStagerV2.stageSession(
            start: start, end: start + dur,
            grav: stillGravity(start: start, durationS: dur),
            hr: sleepHR(start: start, durationS: dur),
            rr: regularRR(start: start, durationS: dur),
            resp: [])
        // V2 emits only the same 4 labels V1's StageSegment uses — "awake" is renamed to "wake".
        let allowed: Set<String> = ["wake", "light", "deep", "rem"]
        for s in segs {
            XCTAssertTrue(allowed.contains(s.stage), "unexpected stage label \(s.stage)")
        }
    }

    /// Degenerate input (too little gravity to grid) must fall back to a single "light" block spanning the
    /// window — exactly the shape V1's `stageSession` returns in the same case, so callers/encoders are safe.
    func testDegenerateInputFallsBackToSingleLightBlock() {
        let start = 1_700_000_000
        let end = start + 3_600
        let segs = SleepStagerV2.stageSession(
            start: start, end: end,
            grav: [GravitySample(ts: start, x: 0, y: 0, z: 1.0)],  // one sample → no epochs
            hr: [], rr: [], resp: [])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.stage, "light")
        XCTAssertEqual(segs.first?.start, start)
        XCTAssertEqual(segs.first?.end, end)
    }

    func testEmptyWindowReturnsLightFallback() {
        // end <= start → features() is empty → the single-segment fallback.
        let segs = SleepStagerV2.stageSession(start: 100, end: 100, grav: [], hr: [], rr: [], resp: [])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.stage, "light")
    }

    // MARK: - recipe invariants

    /// The cycle prior concentrates deep early in the night and suppresses REM in the first ~12 %.
    func testCyclePriorShapesDeepAndRem() {
        let early = SleepStagerV2.cyclePrior(0.05)
        let late = SleepStagerV2.cyclePrior(0.90)
        XCTAssertGreaterThan(early["deep"]!, late["deep"]!, "deep prior is higher early in the night")
        XCTAssertLessThan(early["rem"]!, late["rem"]!, "REM prior is suppressed early, rising toward morning")
        XCTAssertEqual(early["light"]!, 0.0)
        XCTAssertEqual(early["awake"]!, 0.0)
    }

    /// Viterbi over a single epoch returns the highest-emission stage (uniform start, no transitions).
    func testViterbiSingleEpochPicksMaxEmission() {
        let path = SleepStagerV2.viterbi([["deep": 0.1, "rem": 0.1, "light": 5.0, "awake": 0.1]])
        XCTAssertEqual(path, ["light"])
    }

    // MARK: - #690: the V2 flag drives the NORMAL detected-night staging path

    /// A regular R-R stream at ~1 Hz (steady ~1000 ms beats with a small respiratory sinus oscillation),
    /// long enough for the V2 recipe to express both early deep and later REM across the night.
    private func regularRRLong(start: Int, durationS: Int) -> [RRInterval] {
        (0..<durationS).map { i -> RRInterval in
            let rsa = Int(40.0 * sin(2.0 * Double.pi * Double(i) / 4.0))  // ~0.25 Hz breathing
            return RRInterval(ts: start + i, rrMs: 1000 + rsa)
        }
    }

    /// #690 (v7 regression): the "Experimental sleep staging (V2)" toggle must affect a NORMAL detected
    /// night — not only the userEdited self-heal restage. With the flag ON, `detectSleep` stages the
    /// accepted window with V2 (deep + REM present); with the flag OFF it returns the EXACT V1 result, so
    /// the byte-identical default (and the frozen-golden tests) is preserved.
    func testDetectSleepThreadsV2FlagIntoNormalNight() {
        // A 3 h still overnight window (anchored at 01:00 UTC → center ~02:30, clear of the daytime
        // guard band at the default tzOffset=0) with sleep-band HR + a regular R-R stream.
        let start = 1_749_517_200            // 2026-06-10 01:00:00 UTC
        let dur = 3 * 60 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = sleepHR(start: start, durationS: dur)
        let rr = regularRRLong(start: start, durationS: dur)

        // Flag OFF (the default) — V1 path.
        let v1Sessions = SleepStager.detectSleep(hr: hr, rr: rr, gravity: grav)
        XCTAssertEqual(v1Sessions.count, 1, "the still night must be detected")
        let v1 = v1Sessions[0]
        // The detected window's stages MUST equal a direct V1 stageSession over the same span (proof the
        // default path is byte-identical and untouched by the new parameter).
        let v1Direct = SleepStager.stageSession(start: v1.start, end: v1.end,
                                                grav: grav, hr: hr, rr: rr, resp: [])
        XCTAssertEqual(v1.stages.map { [$0.start, $0.end] }, v1Direct.map { [$0.start, $0.end] },
                       "flag OFF must reproduce the exact V1 hypnogram boundaries")
        XCTAssertEqual(v1.stages.map { $0.stage }, v1Direct.map { $0.stage },
                       "flag OFF must reproduce the exact V1 hypnogram labels")

        // Flag ON — the SAME detected window must now be staged by V2.
        let v2Sessions = SleepStager.detectSleep(hr: hr, rr: rr, gravity: grav, useSleepStagerV2: true)
        XCTAssertEqual(v2Sessions.count, 1, "detection is unchanged by the staging flag")
        let v2 = v2Sessions[0]
        // Same accepted window (detection is identical — only staging differs).
        XCTAssertEqual(v2.start, v1.start)
        XCTAssertEqual(v2.end, v1.end)
        // The hypnogram is V2's: it matches a direct V2 stageSession over the accepted span, and (proof
        // the flag actually flipped the engine) it expresses both deep and REM.
        let v2Direct = SleepStagerV2.stageSession(start: v2.start, end: v2.end,
                                                  grav: grav, hr: hr, rr: rr, resp: [])
        XCTAssertEqual(v2.stages.map { $0.stage }, v2Direct.map { $0.stage },
                       "flag ON must produce the V2 hypnogram")
        let v2Stages = Set(v2.stages.map { $0.stage })
        XCTAssertTrue(v2Stages.contains("deep"), "V2 night should express deep")
        XCTAssertTrue(v2Stages.contains("rem"), "V2 night should express REM")
    }
}
