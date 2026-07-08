import XCTest
@testable import StrandAnalytics

/// Pins the `LiveSessionEngine` "silent guardian" behaviour: the recovery-gated band curve and the cue state
/// machine (warm-up silence, in-band silence, push/ease dwell + cool-down, slow-drift suppression, never-
/// fabricate rejection, staleness). Pure value logic — a synthetic HR trace replays deterministically, no
/// strap/BLE seam. GOLDEN VECTORS the Kotlin `LiveSessionEngineTest` mirrors.
/// Design contract: docs/superpowers/specs/2026-07-04-live-sessions-design.md.
final class LiveSessionEngineTests: XCTestCase {

    private let rhr = 55.0
    private let hrMax = 190.0   // reserve = 135

    private func cfg(charge: Double?) -> LiveSessionEngine.Config {
        LiveSessionEngine.Config(restingHR: rhr, hrMax: hrMax, charge: charge)
    }

    /// Feed a constant bpm at 1 Hz for `seconds` updates starting at `fromTs`; collect every Output.
    private func feed(_ e: inout LiveSessionEngine, bpm: Int?, fromTs: Int, seconds: Int) -> [LiveSessionEngine.Output] {
        (0..<seconds).map { e.update(now: fromTs + $0, bpm: bpm) }
    }

    // MARK: - Band curve (golden vectors)

    func test_band_scales_ceiling_with_charge() {
        // Low charge → low, conservative ceiling.
        let low = LiveSessionEngine.band(config: cfg(charge: 10))
        XCTAssertEqual(low.ceilingPctHRR, 0.622, accuracy: 0.001)
        XCTAssertEqual(low.floorPctHRR, 0.472, accuracy: 0.001)

        // 41% Charge — the spec's worked example.
        let mid = LiveSessionEngine.band(config: cfg(charge: 41))
        XCTAssertEqual(mid.ceilingPctHRR, 0.6902, accuracy: 0.001)
        XCTAssertEqual(mid.floorPctHRR, 0.5402, accuracy: 0.001)
        XCTAssertEqual(mid.ceilingBpm, 148.18, accuracy: 0.1)
        XCTAssertEqual(mid.floorBpm, 127.93, accuracy: 0.1)

        // High charge → higher, room to send it.
        let high = LiveSessionEngine.band(config: cfg(charge: 90))
        XCTAssertEqual(high.ceilingPctHRR, 0.798, accuracy: 0.001)
        XCTAssertEqual(high.floorPctHRR, 0.648, accuracy: 0.001)

        XCTAssertGreaterThan(high.ceilingBpm, mid.ceilingBpm)
        XCTAssertGreaterThan(mid.ceilingBpm, low.ceilingBpm)
    }

    func test_band_unknown_charge_is_conservative_midpoint() {
        let b = LiveSessionEngine.band(config: cfg(charge: nil))
        XCTAssertEqual(b.ceilingPctHRR, 0.71, accuracy: 0.001)
        XCTAssertEqual(b.floorPctHRR, 0.56, accuracy: 0.001)
    }

    func test_low_charge_floor_stays_at_or_above_minimum() {
        // Even at zero Charge the band sits at a sane easy-aerobic level (ceiling 0.60, floor 0.45),
        // comfortably above the 0.40 guard — the guard is a defensive net for if the band ever widens.
        let b = LiveSessionEngine.band(config: cfg(charge: 0))
        XCTAssertEqual(b.ceilingPctHRR, 0.60, accuracy: 0.0001)
        XCTAssertEqual(b.floorPctHRR, 0.45, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(b.floorPctHRR, LiveSessionEngine.minFloorPctHRR)
    }

    // MARK: - Guardian behaviour

    func test_warmup_never_buzzes_even_when_out_of_band() {
        var e = LiveSessionEngine(config: cfg(charge: nil), startTs: 1000)
        // 110 bpm is well below the ~[130.6, 150.9] band — but the first 60 s is warm-up.
        let warm = feed(&e, bpm: 110, fromTs: 1000, seconds: 60)
        XCTAssertTrue(warm.allSatisfy { $0.cue == nil }, "no cue may fire during warm-up")
        XCTAssertTrue(warm.allSatisfy { $0.status == .warmup })
    }

    func test_steady_in_band_is_pure_silence_and_accrues_time() {
        var e = LiveSessionEngine(config: cfg(charge: nil), startTs: 0)
        let outs = feed(&e, bpm: 140, fromTs: 0, seconds: 120)   // 140 sits inside the band
        XCTAssertTrue(outs.allSatisfy { $0.cue == nil }, "in-band means never buzz")
        XCTAssertTrue(outs.suffix(30).allSatisfy { $0.position == .inBand })
        XCTAssertGreaterThan(outs.last!.inBandSeconds, 100)
    }

    func test_sustained_too_easy_pushes_once_then_cools_down() {
        var e = LiveSessionEngine(config: cfg(charge: nil), startTs: 1000)
        // 110 bpm (too easy) held for 90 s across warm-up and into active.
        let outs = feed(&e, bpm: 110, fromTs: 1000, seconds: 90)
        let cues = outs.enumerated().filter { $0.element.cue != nil }
        XCTAssertEqual(cues.count, 1, "exactly one push in the first 90 s (dwell + cool-down)")
        XCTAssertEqual(cues.first?.element.cue, .pushNudge)
        // First cue is the first active tick past the 25 s dwell — i.e. at +60 s (warm-up end).
        XCTAssertEqual(cues.first?.offset, 60)
    }

    func test_sharp_climb_over_ceiling_eases_off() {
        var e = LiveSessionEngine(config: cfg(charge: nil), startTs: 1000)
        _ = feed(&e, bpm: 140, fromTs: 1000, seconds: 70)          // settle in-band, past warm-up
        let hot = feed(&e, bpm: 178, fromTs: 1070, seconds: 60)    // sharp jump well over the ceiling
        XCTAssertTrue(hot.contains { $0.cue == .easeOff }, "a sharp over-ceiling breach must ease off")
        XCTAssertFalse(hot.contains { $0.cue == .pushNudge })
    }

    func test_slow_drift_over_ceiling_does_not_ease_off() {
        var e = LiveSessionEngine(config: cfg(charge: nil), startTs: 1000)
        _ = feed(&e, bpm: 140, fromTs: 1000, seconds: 70)
        // A slow ramp 145 -> 170 over 120 s (~3 bpm / 15 s, under the step-change threshold).
        var outs: [LiveSessionEngine.Output] = []
        for i in 0..<120 {
            let bpm = 145 + Int(Double(i) * (25.0 / 120.0))
            outs.append(e.update(now: 1070 + i, bpm: bpm))
        }
        XCTAssertFalse(outs.contains { $0.cue == .easeOff }, "honest slow drift is not a mistake to punish")
    }

    func test_reentry_into_band_is_silent() {
        var e = LiveSessionEngine(config: cfg(charge: nil), startTs: 1000)
        _ = feed(&e, bpm: 110, fromTs: 1000, seconds: 90)          // triggers a push
        let back = feed(&e, bpm: 140, fromTs: 1090, seconds: 40)   // return to band
        XCTAssertTrue(back.allSatisfy { $0.cue == nil }, "crossing back into band never buzzes")
        XCTAssertTrue(back.suffix(20).allSatisfy { $0.position == .inBand })
    }

    func test_impossible_sample_is_rejected() {
        var e = LiveSessionEngine(config: cfg(charge: nil), startTs: 0)
        _ = feed(&e, bpm: 140, fromTs: 0, seconds: 20)
        let out = e.update(now: 20, bpm: 250)     // 250 > hrMax + margin
        XCTAssertFalse(out.sampleArrived, "an above-HRmax reading is not accepted")
        XCTAssertEqual(out.smoothedBpm ?? 0, 140, accuracy: 2.0, "the trend is untouched by the artifact")
    }

    func test_stream_dropout_goes_stale_and_pauses_coaching() {
        var e = LiveSessionEngine(config: cfg(charge: nil), startTs: 0)
        _ = feed(&e, bpm: 110, fromTs: 0, seconds: 20)   // below band, would be building toward a push
        let out = e.update(now: 40, bpm: nil)            // 20 s with no reading
        XCTAssertEqual(out.status, .stale)
        XCTAssertNil(out.smoothedBpm)
        XCTAssertNil(out.cue, "we never buzz on a stale stream")
    }
}
