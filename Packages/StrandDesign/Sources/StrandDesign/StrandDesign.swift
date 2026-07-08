import SwiftUI
#if !os(watchOS)
import Charts   // Swift Charts isn't used by the watch app; the ChartProxy shim below is watchOS-excluded.
#endif

// MARK: - iOS-17 / macOS-14 deprecation shims
//
// NOOP ships a split deployment target — the iOS app targets iOS 17 but the
// macOS app targets macOS 13 — and the Strand/ + StrandDesign sources compile
// into BOTH. The two-parameter `onChange(of:initial:_:)` and the optional
// `ChartProxy.plotFrame` arrived in iOS 17 / macOS 14 and deprecated their
// predecessors, so a blind swap silences the iOS warning yet fails to compile on
// macOS 13 (the new overloads don't exist there). These shims call the modern
// form where available and the legacy form (un-deprecated on macOS 13) otherwise,
// so each deprecation is acknowledged exactly once — here — instead of at every
// call site. Behaviour is identical to a direct `.onChange` / `plotAreaFrame`.

public extension View {
    /// macOS-13-safe `onChange` that hands the closure the new value. Every NOOP
    /// call site reads only the new value, so a single-parameter shim keeps the
    /// existing closures byte-for-byte unchanged (no `_,` rewrite needed).
    @ViewBuilder
    func onChangeCompat<V: Equatable>(
        of value: V,
        perform action: @escaping (V) -> Void
    ) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            self.legacyOnChange(of: value, perform: action)
        }
    }
}

private extension View {
    /// The legacy single-parameter `onChange`, isolated so its deprecation is
    /// acknowledged once. The `@available` annotation marks it deprecated exactly
    /// where the modern overload takes over (iOS 17 / macOS 14), so no warning
    /// fires on the macOS-13 build that genuinely needs this path.
    @available(iOS, introduced: 16.0, deprecated: 17.0)
    @available(macOS, introduced: 13.0, deprecated: 14.0)
    @ViewBuilder
    func legacyOnChange<V: Equatable>(
        of value: V,
        perform action: @escaping (V) -> Void
    ) -> some View {
        self.onChange(of: value, perform: action)
    }
}

#if !os(watchOS)
public extension ChartProxy {
    /// macOS-13-safe plot rect: the optional `plotFrame` on iOS 17 / macOS 14, the
    /// deprecated non-optional `plotAreaFrame` otherwise. `.zero` on a nil anchor
    /// matches the old pre-layout behaviour (call sites guard via `position(forX:)`).
    func plotRectCompat(in geo: GeometryProxy) -> CGRect {
        if #available(iOS 17.0, macOS 14.0, *) {
            guard let frame = plotFrame else { return .zero }
            return geo[frame]
        } else {
            return geo[plotAreaFrame]
        }
    }
}
#endif

/// Strand design system: palette, typography, motion, and signature components
/// (Recovery Ring, Strain Gauge, Hypnogram, Trend/Sparkline charts, Year heat
/// strip, cards, status chips). Dark-only, instrument-grade. See spec §9.
///
/// Token entry points:
/// - `StrandPalette` — every semantic color token (§9.1), recovery/strain sampling.
/// - `StrandFont` — the full type scale with tabular digits (§9.2).
/// - `StrandMotion` — spring presets + durations (§9.6).
public enum StrandDesign {
    public static let version = "0.1.0"
}
