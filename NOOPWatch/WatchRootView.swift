import SwiftUI
import StrandDesign

// MARK: - WatchRootView — the swipeable page deck
//
// The watch app is a deck of full-screen pages you swipe (or turn the Digital Crown) between, each sized to
// exactly ONE screen so nothing ever needs scrolling: the glance (today's synced scores) first, then the
// three on-watch active features. A page-style TabView with the dots showing replaces the old push-nav, so
// every screen is one swipe away and the page indicator makes that obvious. The phone stays the brain for
// the SCORES on the glance; Breathe / Workout / Intervals run on the watch's own sensors + haptics.
struct WatchRootView: View {
    var body: some View {
        TabView {
            WatchGlanceView()
            WatchBreatheView()
            WatchWorkoutView()
            WatchIntervalView()
        }
        // watchOS page TabView shows the page-indicator dots by default; the iOS background-display-mode
        // customisation is unavailable here, so the plain page style is the right call.
        .tabViewStyle(.page)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }
}
