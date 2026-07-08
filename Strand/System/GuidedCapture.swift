import Foundation
import StrandAnalytics

// GuidedCapture.swift - app-side wiring of the guided Sleep/Battery capture. Reuses
// ScheduledDebugExport for the daily morning fire and TestCentre for target/started-at; the
// night-accounting is the pure StrandAnalytics GuidedCaptureProgress. No new scheduling.
// No em-dashes.

enum GuidedCapture {

    /// Start guided capture for a domain: activate the mode, record the target, and arm the existing
    /// scheduled daily export so the morning fire produces the bundle. Reuses the #510 engine; no new
    /// timer. (spec section 6.4)
    @MainActor static func start(_ domain: TestDomain, targetCount: Int) {
        TestCentre.activate(domain)
        TestCentre.setGuidedTarget(targetCount, for: domain)
        ScheduledDebugExport.setEnabled(true)
    }

    /// The guided target for a domain (nights for Sleep, days for Battery), defaulting to the registry's
    /// declared default count when the user has not picked one yet.
    static func target(for domain: TestDomain) -> Int {
        let stored = TestCentre.guidedTarget(domain)
        if stored > 0 { return stored }
        if case let .guided(_, defaultCount)? = TestModeRegistry.mode(domain)?.capture { return defaultCount }
        return 0
    }

    /// Evaluate progress for the Test Centre row. `nightsWithData` is supplied by the caller from the
    /// repository (a count of detected nights since started-at); `nightsElapsed` from the clock.
    static func progress(domain: TestDomain, nightsWithData: Int, nightsElapsed: Int) -> GuidedCaptureProgress {
        GuidedCaptureProgress.evaluate(target: target(for: domain),
                                       nightsWithData: nightsWithData, nightsElapsed: nightsElapsed)
    }
}
