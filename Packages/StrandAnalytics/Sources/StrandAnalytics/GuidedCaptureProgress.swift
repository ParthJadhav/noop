import Foundation

// GuidedCaptureProgress.swift - the pure state machine for the guided "wear it N nights" Sleep
// (and N days Battery) capture. No scheduling, no IO; the app reuses ScheduledDebugExport for the
// daily fire and feeds this the counts. A night with no data is a recorded GAP, never a stall
// (spec section 12: the morning nudge records "no data this night" rather than stalling).
// No em-dashes.

public enum GuidedCaptureProgress: Equatable, Sendable {
    case capturing(done: Int, target: Int)
    case complete

    /// `nightsWithData` = nights (or days) that produced usable data; `nightsElapsed` = calendar
    /// units since start. Complete once enough nights have data, regardless of gaps.
    public static func evaluate(target: Int, nightsWithData: Int, nightsElapsed: Int) -> GuidedCaptureProgress {
        if nightsWithData >= target { return .complete }
        return .capturing(done: nightsWithData, target: target)
    }

    /// The morning-nudge label. A gap night reads honestly via `gapNudge()`.
    public static func label(for state: GuidedCaptureProgress) -> String {
        switch state {
        case .complete: return "Capture complete. Tap Report to export."
        case let .capturing(done, target): return "Captured \(done) of \(target) nights. Wear it again tonight."
        }
    }

    /// The gap-night nudge, shown when a scheduled morning fire found no night data.
    public static func gapNudge() -> String { "No data last night. Wear the strap tonight to continue." }
}
