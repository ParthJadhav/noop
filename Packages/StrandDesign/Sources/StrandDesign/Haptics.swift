import SwiftUI
#if os(watchOS)
import WatchKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Strand Haptics (the tactile sibling of the Motion tokens)
//
// One tasteful tactile vocabulary shared across the app, mirroring StrandMotion. iOS fires
// the Taptic engine; macOS is a no-op. Keep it SPARSE — confirmations and state landings
// only, never per-keystroke or per-frame. The system already honours the user's
// Settings ▸ Sounds & Haptics master switch.

public enum StrandHaptic {
    case selection   // segmented-pill / tab switch / toggle — light, frequent-safe
    case light       // a soft tap (alias kept for press-feedback call sites)
    case commit      // a primary action succeeded (save workout, finish interval)
    case success     // a meaningful milestone (bond success, breathe session done)
    case warning     // a soft "not allowed / invalid"

    #if os(watchOS)
    // watchOS has no UIKit feedback generators; the Taptic engine is driven through WatchKit's
    // `WKHapticType`. Map our vocabulary onto the closest watch haptics so the breathing / interval
    // features (which depend on a real tactile cue) actually buzz on the wrist.
    private func fire() {
        let device = WKInterfaceDevice.current()
        switch self {
        case .selection: device.play(.click)
        case .light:     device.play(.click)
        case .commit:    device.play(.success)
        case .success:   device.play(.success)
        case .warning:   device.play(.failure)
        }
    }
    #elseif canImport(UIKit)
    // Generators are cheap to make; UIKit pools the engine. We don't retain selection
    // generators (tab/pill taps are bursty).
    private func fire() {
        switch self {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .light:     UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .commit:    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .success:   UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:   UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
    #endif

    /// Fire this haptic now. No-op on macOS.
    public func play() {
        #if os(watchOS)
        fire()
        #elseif canImport(UIKit)
        fire()
        #endif
    }
}

public extension View {
    /// Declarative haptic fired when `trigger` changes (iOS 17+ `.sensoryFeedback`; no-op
    /// below / on macOS). Use for value-driven landings: score reveal, bond success,
    /// refresh-done — anything where a state change, not a tap, is the cue.
    @ViewBuilder
    func strandHaptic<V: Equatable>(_ haptic: StrandHaptic, trigger: V) -> some View {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            self.sensoryFeedback(trigger: trigger) { _, _ in haptic.sensory }
        } else { self }
        #else
        self
        #endif
    }
}

#if os(iOS)
@available(iOS 17.0, *)
private extension StrandHaptic {
    var sensory: SensoryFeedback {
        switch self {
        case .selection: return .selection
        case .light:     return .impact(weight: .light)
        case .commit:    return .impact(weight: .heavy)
        case .success:   return .success
        case .warning:   return .warning
        }
    }
}
#endif
