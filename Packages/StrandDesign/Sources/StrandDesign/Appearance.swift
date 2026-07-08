import SwiftUI

/// The data-visualisation colour style: the brand "Titanium & Gold" data ramps, or a "Classic"
/// throwback — the recognizable red → amber → green readiness scale (cool→hot zones, green→red stress,
/// purple REM) that health apps have always used. Works in BOTH light and dark. It only re-colours the
/// DATA encodings (gauge rings, charts, sparklines, scales, stage bands) — never the chrome/surfaces.
///
/// Read globally via `StrandPalette.chartStyle` (set from `@AppStorage(ChartStyle.storageKey)` at the
/// app root); the data-ramp accessors in `StrandPalette` branch on it. The app root keys its content on
/// the raw value so a flip re-renders the visible charts live.
public enum ChartStyle: String, CaseIterable, Identifiable, Sendable {
    case titanium   // brand: gold recovery, amber strain, blue rest
    case classic    // throwback: red→green recovery, cool→hot zones, green→red stress

    public var id: String { rawValue }
    public static let storageKey = "chart.style"

    public var label: String {
        switch self {
        case .titanium: return String(localized: "Default", bundle: .module)
        case .classic:  return String(localized: "Classic", bundle: .module)
        }
    }

    public static func resolve(_ raw: String) -> ChartStyle { ChartStyle(rawValue: raw) ?? .titanium }
}

/// Applies the chart style: sets the global `StrandPalette.chartStyle` (read by the data-ramp
/// accessors) AND keys the content on the raw value so a flip re-renders the visible charts. The
/// global is set during body evaluation, before the keyed content renders, so the new ramps are live
/// on the rebuild. Apply at each app root: `.chartStyle(chartStyleRaw)`.
public extension View {
    func chartStyle(_ raw: String) -> some View {
        StrandPalette.chartStyle = ChartStyle.resolve(raw)
        return self.id("noop.chartStyle.\(raw)")
    }
}

/// The user's appearance preference for the whole app. Persisted via
/// `@AppStorage(AppearanceMode.storageKey)`. `.system` follows the OS (the default);
/// `.light` / `.dark` force a scheme regardless of the system setting.
///
/// Applied once at each app root via `.preferredColorScheme(mode.colorScheme)`. Because every
/// `StrandPalette` token is a dynamic `Color(light:dark:)`, flipping this re-resolves the entire
/// UI automatically — no per-view plumbing.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// The @AppStorage key shared by the app roots and the Settings picker.
    public static let storageKey = "theme.appearance"

    /// Human label for the Settings control.
    public var label: String {
        switch self {
        case .system: return String(localized: "System", bundle: .module)
        case .light:  return String(localized: "Light", bundle: .module)
        case .dark:   return String(localized: "Dark", bundle: .module)
        }
    }

    /// SF Symbol for the Settings control.
    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon.stars"
        }
    }

    /// The `ColorScheme` to force, or `nil` to follow the system (the `.system` case).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Resolve a stored raw value (tolerant of an unknown/missing value → `.system`).
    public static func resolve(_ raw: String) -> AppearanceMode {
        AppearanceMode(rawValue: raw) ?? .system
    }
}

/// The day-cycle scene backdrop behind the Today screen (sunrise / day / dusk / night). Default ON —
/// the scene is the v7 atmosphere. Some people find it distracting and want a plain dark canvas (#698),
/// so this gates whether Today passes a `SceneScreenBackground` into its scaffold. When OFF, Today drops
/// the scene and falls back to the opaque `surfaceBase`; the cards already sit on an opaque canvas, so
/// they stay perfectly readable. Read in `TodayView` via `@AppStorage(SceneBackgroundPrefs.enabledKey)`
/// and toggled from Settings → Appearance. Mirror in Kotlin via `NoopPrefs.showDayCycleBackground`.
public enum SceneBackgroundPrefs {
    /// The @AppStorage key shared by TodayView and the Settings toggle. Default value is `true`.
    public static let enabledKey = "noop.showDayCycleBackground"
}

// MARK: - Light-idiom helpers

/// An additive glow (ring blooms, sparkline heads, hero halos) only reads on a DARK canvas —
/// `.plusLighter` blending on white produces no visible glow and just muddies edges. On dark this
/// applies the additive blend; on light it hides the layer. Self-contained (reads the scheme itself)
/// so every glow becomes a one-token swap from `.blendMode(.plusLighter)` → `.additiveBloom()`.
private struct AdditiveBloom: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        // Dialed back (0.55) — the full-strength additive bloom read as too much glow against the
        // crisper design language. Still present on dark for depth, just restrained.
        if scheme == .dark { content.blendMode(.plusLighter).opacity(0.55) }
        else { content.opacity(0) }
    }
}

/// Card / floating-surface elevation. Dark separates surfaces by a lighter FILL (no resting shadow);
/// light separates white-on-paper by a soft DROP SHADOW. Reads the scheme itself and deepens on hover.
private struct NoopElevation: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var hovering: Bool
    func body(content: Content) -> some View {
        let lightShadow = Color(hex: "#1A2230")
        return content.shadow(
            color: scheme == .light ? lightShadow.opacity(hovering ? 0.16 : 0.09)
                                    : Color.black.opacity(hovering ? 0.45 : 0.0),
            radius: scheme == .light ? (hovering ? 14 : 10) : (hovering ? 18 : 0),
            x: 0, y: scheme == .light ? (hovering ? 5 : 3) : (hovering ? 8 : 0)
        )
    }
}

public extension View {
    /// Apply the additive glow only on dark; hide it on light. See `AdditiveBloom`.
    func additiveBloom() -> some View { modifier(AdditiveBloom()) }

    /// Apply the per-scheme card/surface elevation (shadow on light, lighter-fill idiom on dark).
    func noopElevation(hovering: Bool = false) -> some View { modifier(NoopElevation(hovering: hovering)) }
}
