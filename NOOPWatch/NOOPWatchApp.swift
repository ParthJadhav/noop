import SwiftUI
import StrandDesign

// MARK: - NOOPWatch — the watchOS glance app
//
// The iPhone is the brain. M1 already computes Charge / Effort / Rest with confidence and provenance;
// this watch app ONLY displays the latest snapshot the phone pushes over WatchConnectivity. It never
// recomputes a score. The one thing the watch measures locally is its OWN heart rate (HealthKit), shown
// as a live readout alongside the synced scores.
//
// Two long-lived objects own the data:
//   - WatchScoreStore  receives the phone's snapshot, persists it to the shared App Group, drives the
//                      complication reload, and publishes it to the glance.
//   - WatchLiveHR      streams the watch's own heart rate (guarded behind HealthKit authorization).
//
// Both are created once here and handed to the glance as environment objects so the view stays pure.

@main
struct NOOPWatchApp: App {
    // Created once for the app's lifetime. The store activates WCSession on init so a snapshot the
    // phone sent while the app was backgrounded is delivered as soon as we come up.
    @StateObject private var store = WatchScoreStore()
    @StateObject private var liveHR = WatchLiveHR()

    init() {
        #if DEBUG
        Self.seedDemoSnapshotIfNeeded()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(store)
                .environmentObject(liveHR)
                // The watch app is dark-only to match the Apple-Fitness-x-WHOOP look. StrandPalette
                // tokens resolve their dark values here, so the rings read on the near-black canvas.
                .preferredColorScheme(.dark)
        }
    }

    // Normally the glance. In DEBUG only, a NOOP_DEMO_SCREEN env var can root the app directly at one of
    // the active features so each can be screenshotted on the simulator (which can't tap to navigate).
    // Compiled out of release builds.
    @ViewBuilder private var rootView: some View {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["NOOP_DEMO_SCREEN"] {
        case "breathe":   WatchBreatheView()
        case "workout":   WatchWorkoutView()
        case "intervals": WatchIntervalView()
        case "glance":    WatchGlanceView()
        default:          WatchRootView()
        }
        #else
        WatchRootView()
        #endif
    }

    #if DEBUG
    /// DEBUG-ONLY screenshot aid. On a fresh sim there is no paired phone to push scores, so the glance
    /// would sit on its empty "open NOOP on your iPhone" state and the rings never render. When nothing
    /// has ever synced we write ONE believable sample snapshot into the shared app group so the rings
    /// draw for screenshots. Guarded so it never overwrites a real synced snapshot, and the whole thing
    /// is compiled out of release builds, so it can never ship.
    static func seedDemoSnapshotIfNeeded() {
        guard WatchScoreSnapshot.load() == nil else { return }
        let demo = WatchScoreSnapshot(charge: 72, chargeCalibrating: false,
                                      effort: 61, effortCalibrating: false,
                                      rest: 84, restCalibrating: false,
                                      hr: 58, sleepSummary: "7h 12m",
                                      asOf: Date())
        demo.save()
    }
    #endif
}
