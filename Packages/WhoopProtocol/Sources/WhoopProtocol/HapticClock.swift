import Foundation

/// Haptic Clock (#460): turn a wall-clock time into a deterministic list of wrist buzzes so a user
/// can read the time off the strap without looking at a screen — a long pulse counts tens, a short
/// pulse counts units, in the order hour-tens, hour-units, minute-tens, minute-units.
///
/// This is a PURE, platform-agnostic encoder: time-in, pulse-list-out, no I/O and no BLE. The trigger
/// (`BLEManager.buzzTimeNow()` on Apple, `WhoopBleClient.buzzTimeNow()` on Android) walks the list and
/// fires each pulse through the EXISTING maverick notification buzz; only the *schedule* of buzzes is
/// new, the buzz itself is the hardware-confirmed one. The Kotlin twin is
/// `android/app/src/main/java/com/noop/protocol/HapticClock.kt`; the two pulse lists are pinned
/// identical by matching unit tests on both platforms (e.g. 3:25 → the same list).
///
/// Reading the buzzes:
///   • LONG pulse  = one "ten"   in the current digit group
///   • SHORT pulse = one "unit"  in the current digit group
///   • a short gap separates pulses; a long gap separates the four digit groups (HH-tens, HH-units,
///     MM-tens, MM-units); an extra-long gap separates the hour block from the minute block.
///   • a digit of 0 emits NO pulse — the group is signalled only by the surrounding group gaps, so
///     e.g. 10:05 is [long](ten-hour) · gap · (no hour-units) · BLOCK · (no min-tens) · gap · short×5.
public enum HapticClock {

    /// One buzz instruction: buzz the wrist for `durationMs`, then stay silent for `gapMs`.
    /// `Equatable` so tests can assert the exact list; plain ints keep it portable to Kotlin.
    public struct Pulse: Equatable {
        public let durationMs: Int
        public let gapMs: Int
        public init(durationMs: Int, gapMs: Int) {
            self.durationMs = durationMs
            self.gapMs = gapMs
        }

        /// Whether this is a "tens" pulse (long buzz) versus a "units" pulse (short). Lets a trigger
        /// weight the buzz (heavier vs lighter) without reaching into the encoder's private timing
        /// table — the constants stay module-internal. Kotlin twin: `Pulse.isLong`.
        public var isLong: Bool { durationMs >= HapticClock.longMs }
    }

    // Pulse + gap timing (ms). Kept in lock-step with HapticClock.kt — change both together.
    // #981: the buzz itself is a fixed hardware pattern, so durationMs+gapMs is only the start-to-start
    // SPACING between buzzes. The old 250ms intra-gap left near-zero silence between unit taps, so they
    // blended on the wrist and were "almost impossible to distinguish". Widened gaps (intra-gap most of
    // all) give clear silence between taps and between digit groups while keeping the sequence practical.
    static let longMs = 550        // a "tens" pulse
    static let shortMs = 200       // a "units" pulse
    static let intraGapMs = 450    // silence between two pulses inside one digit group
    static let groupGapMs = 900    // silence between adjacent digit groups
    static let blockGapMs = 1500   // silence between the hour block and the minute block

    /// Encode `hour`:`minute` into the buzz schedule.
    /// - Parameters:
    ///   - hour: hour of day, 0...23 (24-hour input — the app already stores wall time this way).
    ///   - minute: minute of hour, 0...59.
    ///   - is24h: if `false`, the hour is mapped to 12-hour clock form (12,1...11) before encoding,
    ///            so the wrist count matches a 12-hour face. AM/PM is NOT signalled (the user knows
    ///            roughly what part of day it is); only the dial reading is buzzed out.
    /// - Returns: the ordered pulse list. Empty only for the degenerate all-zero 24h midnight 0:00,
    ///   which has no pulses to emit; callers should treat an empty list as "nothing to buzz".
    public static func pulses(hour: Int, minute: Int, is24h: Bool) -> [Pulse] {
        // Clamp defensively rather than trap — this can be driven from a stored pref or a strap tap.
        let h24 = min(max(hour, 0), 23)
        let m = min(max(minute, 0), 59)
        let displayHour = is24h ? h24 : twelveHour(h24)

        let hourTens = displayHour / 10
        let hourUnits = displayHour % 10
        let minTens = m / 10
        let minUnits = m % 10

        var out: [Pulse] = []

        // Hour block: tens group, then units group.
        appendGroup(&out, count: hourTens, durationMs: longMs)
        closeGroup(&out, with: groupGapMs)
        appendGroup(&out, count: hourUnits, durationMs: shortMs)
        // Separate hour block from minute block with the longer block gap.
        closeGroup(&out, with: blockGapMs)

        // Minute block: tens group, then units group.
        appendGroup(&out, count: minTens, durationMs: longMs)
        closeGroup(&out, with: groupGapMs)
        appendGroup(&out, count: minUnits, durationMs: shortMs)

        // The final pulse needs no trailing gap — trim it so the sequence ends on a buzz.
        if let last = out.last {
            out[out.count - 1] = Pulse(durationMs: last.durationMs, gapMs: 0)
        }
        return out
    }

    /// 24-hour hour → 12-hour dial reading (0→12, 13→1 … 23→11). Noon stays 12.
    static func twelveHour(_ h24: Int) -> Int {
        let h = h24 % 12
        return h == 0 ? 12 : h
    }

    /// Append `count` identical pulses (each duration `durationMs`) separated by the intra-group gap.
    private static func appendGroup(_ out: inout [Pulse], count: Int, durationMs: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            out.append(Pulse(durationMs: durationMs, gapMs: intraGapMs))
        }
    }

    /// Widen the trailing pulse's gap to at least `gapMs` (a group/block separator). If nothing has
    /// been emitted yet (a leading zero digit group, e.g. minute-tens of 0), there is no pulse to
    /// widen — the missing pulse is itself the "0", and the surrounding gaps still bound the groups,
    /// so this is a no-op. We take the MAX rather than overwrite so that when later groups are empty
    /// (e.g. 12:00 has no minute pulses) an earlier, wider block separator isn't clobbered by a
    /// narrower group separator that follows it on the same trailing pulse.
    private static func closeGroup(_ out: inout [Pulse], with gapMs: Int) {
        guard let last = out.last else { return }
        out[out.count - 1] = Pulse(durationMs: last.durationMs, gapMs: max(last.gapMs, gapMs))
    }
}
