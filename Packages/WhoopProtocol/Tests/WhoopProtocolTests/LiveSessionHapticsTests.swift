import XCTest
@testable import WhoopProtocol

/// Pins the two Live Session wrist signals to exact pulse lists — the GOLDEN VECTORS the Kotlin
/// `LiveSessionHapticsTest` mirrors byte-for-byte (cross-platform parity). Distinguishable by feel:
/// push = two LIGHT taps, easeOff = three HEAVY taps. Design: docs/superpowers/specs/2026-07-04-live-sessions-design.md.
final class LiveSessionHapticsTests: XCTestCase {

    func test_push_is_two_light_taps() {
        let pulses = LiveSessionHaptics.pulses(for: .push)
        XCTAssertEqual(pulses, [
            HapticClock.Pulse(durationMs: 200, gapMs: 450),
            HapticClock.Pulse(durationMs: 200, gapMs: 0),   // ends on a buzz, no trailing gap
        ])
        XCTAssertTrue(pulses.allSatisfy { !$0.isLong }, "push taps are light (short)")
    }

    func test_easeOff_is_three_heavy_taps() {
        let pulses = LiveSessionHaptics.pulses(for: .easeOff)
        XCTAssertEqual(pulses, [
            HapticClock.Pulse(durationMs: 550, gapMs: 450),
            HapticClock.Pulse(durationMs: 550, gapMs: 450),
            HapticClock.Pulse(durationMs: 550, gapMs: 0),
        ])
        XCTAssertTrue(pulses.allSatisfy { $0.isLong }, "ease-off taps are heavy (long)")
    }

    func test_signals_are_distinguishable_by_count_and_weight() {
        let push = LiveSessionHaptics.pulses(for: .push)
        let ease = LiveSessionHaptics.pulses(for: .easeOff)
        XCTAssertEqual(push.count, 2)
        XCTAssertEqual(ease.count, 3)
        XCTAssertNotEqual(push.first?.isLong, ease.first?.isLong)
    }
}
