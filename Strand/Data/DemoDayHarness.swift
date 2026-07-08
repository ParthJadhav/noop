#if DEBUG
import Foundation

// MARK: - DEBUG-only day-cycle screenshot harness
//
// A promo-animation aid (NOT shipped). When the process is launched with `--demo-hour <Int>` (the two
// args arrive separately via `simctl launch`), this pins the Today screen to a single believable
// "moment in the day": it swaps the day-cycle SCENE to that hour's illustration and overrides a small
// set of Today read-outs (Effort, greeting, readiness badge, Synthesis copy, and the Stress / HRV /
// Resting-HR cards) with a hand-tuned per-hour value so a sweep of `--demo-hour 2 … 22` captures every
// background with a plausible stat progression across the day.
//
// Gating: the WHOLE file is `#if DEBUG`, so it is stripped from every Release build. At runtime nothing
// changes unless `--demo-hour` is present: `applyLaunchArgsIfNeeded()` leaves `active == nil` otherwise,
// and every override in TodayView is `(DemoDayHarness.active != nil)`-gated — so with no arg the screen
// is byte-identical to the seeded demo. Pairs with `--demo-seed` (AppleDemoSeeder), which supplies the
// underlying synthetic dataset; this harness only re-presents a few values on top of it. Everything here
// is SYNTHETIC — nothing is real biometric data.

/// One pinned "moment in the day" the harness renders. All values are presentation-only overrides.
struct DemoDayFrame {
    let hour: Int
    let greeting: String
    let readiness: String
    let effort: Double      // NOOP 0–100 Effort axis
    let hrvMs: Int
    let rhrBpm: Int
    let stress0to3: Int
    let synthHeadline: String
    let synthBody: String
}

enum DemoDayHarness {

    /// The pinned frame, or nil when `--demo-hour` was not passed (→ zero behaviour change).
    static private(set) var active: DemoDayFrame?

    /// The override hour for the day-cycle scene, when a frame is active.
    static var hour: Int? { active?.hour }

    /// The ten frames, one per captured hour, ordered through the day. Hand-tuned so the stat
    /// progression reads believably as the day advances (Effort climbs and settles, HRV/RHR ebb and
    /// flow, stress peaks midday). The scene each hour resolves to is owned by `DayCycleScene`.
    static let frames: [DemoDayFrame] = [
        DemoDayFrame(hour: 2,  greeting: "Good night",     readiness: "Solid",    effort: 3,  hrvMs: 84, rhrBpm: 50, stress0to3: 0, synthHeadline: "Resting",      synthBody: "Deep in the night. Your body is recovering."),
        DemoDayFrame(hour: 5,  greeting: "Early start",    readiness: "Solid",    effort: 5,  hrvMs: 81, rhrBpm: 51, stress0to3: 0, synthHeadline: "Waking",       synthBody: "First light. Recovery is looking strong."),
        DemoDayFrame(hour: 6,  greeting: "Good morning",   readiness: "Solid",    effort: 7,  hrvMs: 78, rhrBpm: 53, stress0to3: 1, synthHeadline: "Ready",        synthBody: "You are rested and set for the day ahead."),
        DemoDayFrame(hour: 7,  greeting: "Good morning",   readiness: "Solid",    effort: 11, hrvMs: 73, rhrBpm: 57, stress0to3: 1, synthHeadline: "Ready",        synthBody: "Recovery is solid. A good day to push."),
        DemoDayFrame(hour: 8,  greeting: "Good morning",   readiness: "Moderate", effort: 18, hrvMs: 67, rhrBpm: 61, stress0to3: 2, synthHeadline: "Warming up",   synthBody: "Effort is building as the day gets going."),
        DemoDayFrame(hour: 10, greeting: "Good morning",   readiness: "Moderate", effort: 31, hrvMs: 62, rhrBpm: 64, stress0to3: 2, synthHeadline: "In the swing", synthBody: "A steady load through the morning."),
        DemoDayFrame(hour: 14, greeting: "Good afternoon", readiness: "Moderate", effort: 56, hrvMs: 55, rhrBpm: 71, stress0to3: 2, synthHeadline: "Pushing",      synthBody: "Midday effort is climbing. Stay hydrated."),
        DemoDayFrame(hour: 17, greeting: "Good evening",   readiness: "Moderate", effort: 69, hrvMs: 58, rhrBpm: 66, stress0to3: 1, synthHeadline: "Easing off",   synthBody: "A strong day logged. Start winding down."),
        DemoDayFrame(hour: 19, greeting: "Good evening",   readiness: "Solid",    effort: 77, hrvMs: 63, rhrBpm: 61, stress0to3: 1, synthHeadline: "Winding down", synthBody: "Effort is in. Time to let your body recover."),
        DemoDayFrame(hour: 22, greeting: "Good night",     readiness: "Solid",    effort: 84, hrvMs: 71, rhrBpm: 55, stress0to3: 0, synthHeadline: "Time for bed", synthBody: "A big day done. Prioritise sleep tonight."),
    ]

    /// Scan the launch args for `--demo-hour <Int>` and pin the matching frame (exact hour, else the
    /// nearest by absolute hour distance). Call ONCE at launch before the first Today render. Safe to
    /// call always: with no `--demo-hour` present `active` stays nil and nothing changes. Idempotent.
    static func applyLaunchArgsIfNeeded() {
        let args = CommandLine.arguments
        // `--demo-hour` and its value arrive as two separate args (simctl). Find the flag, read the next.
        guard let flagIdx = args.firstIndex(of: "--demo-hour"),
              args.index(after: flagIdx) < args.endIndex,
              let wanted = Int(args[args.index(after: flagIdx)]) else { return }
        guard !frames.isEmpty else { return }
        active = frames.first(where: { $0.hour == wanted })
            ?? frames.min(by: { abs($0.hour - wanted) < abs($1.hour - wanted) })
    }
}
#endif
