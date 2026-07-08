import Foundation

/// Live Sessions (silent guardian) — the two, and only two, wrist signals the coach ever sends. Pure,
/// platform-agnostic: signal-in, pulse-list-out, no I/O and no BLE. The trigger (`BLEManager.buzz` on Apple,
/// `WhoopBleClient` on Android) walks the list and fires each pulse through the EXISTING hardware buzz,
/// weighting it by `Pulse.isLong` (a long pulse = the heavier 2-loop buzz, a short pulse = the lighter
/// 1-loop) — the same mechanism the Haptic Clock and Breath Pacer already use.
///
/// The vocabulary is deliberately tiny and distinguishable by FEEL alone, mid-effort, no screen:
///   • `push`    — two LIGHT taps  → "give a bit more"
///   • `easeOff` — three HEAVY taps → "ease off, today can't pay for this"
///
/// Kotlin twin: `android/app/src/main/java/com/noop/protocol/LiveSessionHaptics.kt`; the two pulse lists are
/// pinned identical by matching unit tests on both platforms. Design contract:
/// docs/superpowers/specs/2026-07-04-live-sessions-design.md.
public enum LiveSessionHaptics {

    /// The coach's entire signalling vocabulary. Silence (no signal) is the third, most common, state and
    /// carries no pulses at all — it is never sent, only felt as the absence of these two.
    public enum Signal: Equatable, Sendable {
        case push      // too easy for today
        case easeOff   // too hard for today
    }

    /// The ordered buzz list for a signal. Reuses `HapticClock`'s pulse timing (module-internal) so the two
    /// features stay in lock-step: `shortMs`/`longMs` durations, `intraGapMs` spacing, final gap trimmed to 0.
    public static func pulses(for signal: Signal) -> [HapticClock.Pulse] {
        switch signal {
        case .push:
            return trimmed([
                HapticClock.Pulse(durationMs: HapticClock.shortMs, gapMs: HapticClock.intraGapMs),
                HapticClock.Pulse(durationMs: HapticClock.shortMs, gapMs: HapticClock.intraGapMs),
            ])
        case .easeOff:
            return trimmed([
                HapticClock.Pulse(durationMs: HapticClock.longMs, gapMs: HapticClock.intraGapMs),
                HapticClock.Pulse(durationMs: HapticClock.longMs, gapMs: HapticClock.intraGapMs),
                HapticClock.Pulse(durationMs: HapticClock.longMs, gapMs: HapticClock.intraGapMs),
            ])
        }
    }

    /// The sequence ends on a buzz, not a gap — trim the final pulse's trailing gap to 0.
    private static func trimmed(_ pulses: [HapticClock.Pulse]) -> [HapticClock.Pulse] {
        guard let last = pulses.last else { return pulses }
        var out = pulses
        out[out.count - 1] = HapticClock.Pulse(durationMs: last.durationMs, gapMs: 0)
        return out
    }
}
