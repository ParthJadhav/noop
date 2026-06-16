import SwiftUI

// MARK: - The locked component system
//
// Every screen composes ONLY these. Fixed dimensions + one spacing scale guarantee
// the uniform, instrument-grade look from the reference. Do not invent ad-hoc cards.

public enum NoopMetrics {
    public static let cardRadius: CGFloat = 18   // Bevel continuous radius (18–22pt)
    public static let cardPadding: CGFloat = 16
    public static let gap: CGFloat = 12          // gap between cards
    public static let sectionGap: CGFloat = 28   // gap between sections
    public static let screenPadding: CGFloat = 24
    public static let tileHeight: CGFloat = 108  // every metric tile is this tall
    public static let chartHeight: CGFloat = 220
    public static let hypnogramBandMinThickness: CGFloat = 14  // floor so short stages read as bars, not ticks
    public static let tabBarClearance: CGFloat = 76  // iOS: extra bottom scroll room so the last card clears the floating tab bar
}

// MARK: - iOS sheet presentation idiom

#if os(iOS)
public extension View {
    /// The house iOS sheet idiom: the drag indicator (the touch affordance that says
    /// "swipe to dismiss") plus detents. macOS sheets are free-floating windows and must
    /// NOT receive this, so the helper is iOS-only and call sites stay shared via #if.
    /// `largeFirst == false` opens at .medium with .large reachable by dragging up (short
    /// forms); `true` opens full-height (long scrolls).
    func noopSheetPresentation(largeFirst: Bool) -> some View {
        self
            .presentationDragIndicator(.visible)
            .presentationDetents(largeFirst ? [.large] : [.medium, .large])
    }
}
#endif

// MARK: - Surface

/// The one card surface — now the Bevel frosted card. PUBLIC API is unchanged
/// (padding + content); an optional `tint` was ADDED (defaulted) so callers can opt
/// into a per-domain accent wash without breaking existing call sites.
public struct NoopCard<Content: View>: View {
    private let padding: CGFloat
    private let tint: Color?
    @ViewBuilder private let content: () -> Content
    #if os(macOS)
    @State private var hover = false
    #endif
    public init(padding: CGFloat = NoopMetrics.cardPadding, tint: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding; self.tint = tint; self.content = content
    }
    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hover chrome (fill + border + shadow) lives in the background so its animation is
            // scoped to the card surface ONLY. It must never animate the content() subtree, or a
            // chart inside re-animates its line every time the cursor crosses the card. (#104)
            .background { cardSurface }
        #if os(macOS)
            .onHover { hover = $0 }
        #endif
    }

    // Touch can't hover, so iOS renders only the static resting frosted surface — no
    // hover @State, no .onHover tracking, no .animation node. That trims the modifier
    // count on every card, which multiplies across long scrolling lists. macOS adds the
    // hover emphasis border on top (with the #104 animation scoping) unchanged.
    @ViewBuilder private var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
        #if os(macOS)
        FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.cardRadius)
            .overlay(
                shape.strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1).opacity(hover ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.16), value: hover)
        #else
        FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.cardRadius)
        #endif
    }
}

// MARK: - Section header

public struct SectionHeader: View {
    let overline: LocalizedStringKey?; let title: LocalizedStringKey; let trailing: String?
    public init(_ title: LocalizedStringKey, overline: LocalizedStringKey? = nil, trailing: String? = nil) {
        self.title = title; self.overline = overline; self.trailing = trailing
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let overline { Text(overline).strandOverline() }
                Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            if let trailing {
                Text(trailing).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

// MARK: - Metric tile (UNIFORM fixed height)

public struct StatTile: View {
    let label: LocalizedStringKey, value: String
    var caption: String? = nil
    var accent: Color = StrandPalette.textPrimary
    var delta: String? = nil
    var deltaColor: Color = StrandPalette.textTertiary
    var sparkline: [Double]? = nil
    var sparkColor: Color = StrandPalette.accent

    public init(label: LocalizedStringKey, value: String, caption: String? = nil,
                accent: Color = StrandPalette.textPrimary, delta: String? = nil,
                deltaColor: Color = StrandPalette.textTertiary,
                sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent) {
        self.label = label; self.value = value; self.caption = caption; self.accent = accent
        self.delta = delta; self.deltaColor = deltaColor; self.sparkline = sparkline; self.sparkColor = sparkColor
    }

    public var body: some View {
        // The tile borrows its accent as a faint card wash, so each metric tile reads as
        // part of its colour world while staying legible on the deep blue-black.
        NoopCard(padding: 14, tint: accent) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).strandOverline()
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value).font(StrandFont.number(26)).foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    // Trend chip — the delta as a tinted pill with a direction arrow.
                    if let delta { TrendChip(text: delta, color: deltaColor) }
                }
                if let sparkline, sparkline.count > 1 {
                    Sparkline(values: sparkline, gradient: Gradient(colors: [sparkColor.opacity(0.5), sparkColor]))
                        .frame(height: 22).padding(.top, 4)
                        .accessibilityHidden(true)
                }
                if let caption {
                    Text(caption).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                        .padding(.top, 2)
                }
            }
        }
        .frame(height: NoopMetrics.tileHeight)
        // One VoiceOver stop per tile (label, value, caption, delta) instead of up
        // to four fragmented stops; the decorative sparkline is hidden above.
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Trend chip — a small tinted delta pill with a direction arrow.

/// A compact trend pill: an up/down/flat arrow + the delta text, tinted to `color`.
/// Inferred direction comes from a leading +/− in the text (else flat). Sits in the
/// corner of a StatTile or beside a metric value.
public struct TrendChip: View {
    let text: String
    var color: Color = StrandPalette.textTertiary
    public init(text: String, color: Color = StrandPalette.textTertiary) {
        self.text = text; self.color = color
    }
    private var symbol: String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+") || t.hasPrefix("▲") || t.lowercased().hasPrefix("up") { return "arrow.up.right" }
        if t.hasPrefix("-") || t.hasPrefix("−") || t.hasPrefix("▼") || t.lowercased().hasPrefix("down") { return "arrow.down.right" }
        return "minus"
    }
    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(text).font(StrandFont.captionNumber)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule(style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Chart card (UNIFORM: header + fixed chart body + footer)

public struct ChartCard<ChartBody: View, Footer: View>: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    var trailing: String? = nil
    var height: CGFloat = NoopMetrics.chartHeight
    var tint: Color? = nil
    @ViewBuilder let chart: () -> ChartBody
    @ViewBuilder let footer: () -> Footer

    public init(title: LocalizedStringKey, subtitle: String? = nil, trailing: String? = nil,
                height: CGFloat = NoopMetrics.chartHeight, tint: Color? = nil,
                @ViewBuilder chart: @escaping () -> ChartBody,
                @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
        self.height = height; self.tint = tint; self.chart = chart; self.footer = footer
    }

    public var body: some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).strandOverline()
                        if let subtitle { Text(subtitle).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary) }
                    }
                    Spacer()
                    if let trailing { Text(trailing).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary) }
                }
                chart().frame(height: height)
                let f = footer()
                if !(f is EmptyView) {
                    Divider().overlay(StrandPalette.hairline)
                    f
                }
            }
        }
    }
}

/// A footer row of small "label / value" stats for ChartCard.
public struct ChartFooter: View {
    let items: [(LocalizedStringKey, String)]
    public init(_ items: [(LocalizedStringKey, String)]) { self.items = items }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.0).textCase(.uppercase).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    Text(it.1).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Insight card

public struct InsightCard: View {
    let category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey
    var statusColor: Color = StrandPalette.accent
    var tint: Color? = nil
    public init(category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey, statusColor: Color = StrandPalette.accent, tint: Color? = nil) {
        self.category = category; self.status = status; self.detail = detail; self.statusColor = statusColor; self.tint = tint
    }
    public var body: some View {
        // Defaults the card wash to the status colour so the coaching card sits in the
        // same colour world as the score it summarises (e.g. gold for Charge). The
        // insight card reads a touch stronger than a tile: an explicit hue wash
        // (.14 → .04) + a matching .22 hue border on top of the frosted surface.
        let hue = tint ?? statusColor
        let shape = RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
        return NoopCard(padding: 18, tint: hue) {
            VStack(alignment: .leading, spacing: 8) {
                Text(category).strandOverline()
                Text(status).font(StrandFont.rounded(28, weight: .bold)).foregroundStyle(statusColor)
                Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(
            shape.fill(
                LinearGradient(
                    colors: [hue.opacity(0.14), hue.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        )
        .overlay(shape.strokeBorder(hue.opacity(0.22), lineWidth: 1))
    }
}

// MARK: - Range control (the ONE segmented pill control, used everywhere)

public struct SegmentedPillControl<T: Hashable>: View {
    let items: [T]
    let label: (T) -> String
    @Binding var selection: T
    public init(_ items: [T], selection: Binding<T>, label: @escaping (T) -> String) {
        self.items = items; self._selection = selection; self.label = label
    }
    public var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let sel = item == selection
                Button {
                    guard selection != item else { return }   // re-tapping the active segment stays silent
                    StrandHaptic.selection.play()
                    withAnimation(StrandMotion.interactive) { selection = item }
                } label: {
                    Text(label(item))
                        .font(StrandFont.captionNumber)
                        // Active segment = gold-gradient pill + dark gold-deep ink; inactive
                        // = tertiary text on the bare inset track.
                        .foregroundStyle(sel ? StrandPalette.goldDeepText : StrandPalette.textTertiary)
                        .frame(minWidth: 32)
                        .padding(.vertical, 6).padding(.horizontal, 11)
                        .background(
                            Capsule(style: .continuous)
                                .fill(sel ? AnyShapeStyle(LinearGradient(gradient: StrandPalette.goldGradient, startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.clear))
                                .shadow(color: sel ? StrandPalette.gold.opacity(0.4) : .clear, radius: sel ? 6 : 0, y: 1)
                        )
                        // On iOS guarantee the ≥44pt touch target (height only — width is
                        // already ≥54pt) without bloating the denser Mac control, then make
                        // the whole area tappable so the transparent margin counts as a hit.
                        #if os(iOS)
                        .frame(minHeight: 44)
                        #endif
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Announce the active range to VoiceOver and give a non-colour cue.
                .accessibilityAddTraits(sel ? .isSelected : [])
            }
        }
        .padding(3)
        .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }
}

// MARK: - Badges

public struct SourceBadge: View {
    let text: LocalizedStringKey; var tint: Color = StrandPalette.accent
    public init(_ text: LocalizedStringKey, tint: Color = StrandPalette.accent) { self.text = text; self.tint = tint }
    public var body: some View {
        Text(text).textCase(.uppercase).font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(0.5)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule(style: .continuous))
            .foregroundStyle(tint)
            .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.34), lineWidth: 1))
    }
}

// MARK: - Numeric field helpers (iOS soft-keyboard)

public extension View {
    /// Configures a TextField for whole-number-or-decimal entry on iOS: the decimal-pad
    /// keyboard (handles both integer Avg-HR and decimal calories). No-op on macOS
    /// (hardware keyboard), so the SAME shared view compiles on both. Pair with
    /// `.keyboardDoneToolbar(...)` on the enclosing view to add a Done button (the decimal
    /// pad has no return key).
    func numericKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad).textContentType(nil)
        #else
        self
        #endif
    }

    /// Adds a single trailing "Done" button to the software-keyboard accessory bar that
    /// resigns the given focus binding. iOS-only; the keyboard toolbar is hosted by the
    /// keyboard itself, so it works inside a sheet with no NavigationStack. No-op on macOS.
    func keyboardDoneToolbar<Value: Hashable>(_ focus: FocusState<Value?>.Binding) -> some View {
        #if os(iOS)
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus.wrappedValue = nil }
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        #else
        self
        #endif
    }
}

// MARK: - Buttons (Titanium & Gold) — ADDED additively, no existing API touched.
//
// Three house button styles for primary actions, secondary chrome and ghost/gold
// CTAs. Drop in via `.buttonStyle(.noopPrimary)` etc. on any `Button`. All read off
// the new gold tokens so they match Apple ⇄ Android. Pressed = subtle dim + scale.

/// Primary call-to-action: gold-gradient fill, dark gold-deep ink (700), rounded 13.
public struct NoopPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(StrandFont.body.weight(.bold))
            .foregroundStyle(StrandPalette.goldDeepText)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(gradient: StrandPalette.goldGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            // The signature gold cast-shadow (0 10px 22px -8px gold@.6).
            .shadow(color: StrandPalette.gold.opacity(pressed ? 0.25 : 0.6), radius: 14, x: 0, y: 8)
            .opacity(pressed ? 0.9 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Secondary: inset well + 1px white-12 border + primary text. Quieter than gold.
public struct NoopSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return configuration.label
            .font(StrandFont.body.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(shape.fill(StrandPalette.surfaceInset))
            .overlay(shape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .opacity(pressed ? 0.82 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Ghost / gold: transparent + 1px gold@.3 hairline + gold text. Tertiary CTA.
public struct NoopGhostButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return configuration.label
            .font(StrandFont.body.weight(.semibold))
            .foregroundStyle(StrandPalette.gold)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(shape.fill(StrandPalette.gold.opacity(pressed ? 0.10 : 0)))
            .overlay(shape.strokeBorder(StrandPalette.gold.opacity(0.3), lineWidth: 1))
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == NoopPrimaryButtonStyle {
    /// Gold-gradient primary CTA.
    static var noopPrimary: NoopPrimaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == NoopSecondaryButtonStyle {
    /// Inset secondary button.
    static var noopSecondary: NoopSecondaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == NoopGhostButtonStyle {
    /// Transparent gold-outline ghost button.
    static var noopGhost: NoopGhostButtonStyle { .init() }
}

// MARK: - Score state pill (SOLID / BUILDING / CALIBRATING / LIVE)
//
// ADDED additively — the existing `StatePill` (tone-based, in StatePill.swift) is
// untouched. This is the score-lifecycle chip the new design calls for: SOLID = gold
// fill, BUILDING = blue, CALIBRATING = slate, LIVE = gold dot with a pulsing halo.

public enum ScoreState: Sendable {
    case solid        // a settled, trustworthy score
    case building     // accruing nights, not yet settled
    case calibrating  // baseline still forming
    case live         // streaming right now

    /// The chip's hue, drawn from the re-pointed palette (gold / blue / slate).
    public var color: Color {
        switch self {
        case .solid, .live: return StrandPalette.gold
        case .building:     return StrandPalette.sleepLight   // #4A90E2 blue
        case .calibrating:  return StrandPalette.textTertiary // #8A94A4 slate
        }
    }
    public var label: LocalizedStringKey {
        switch self {
        case .solid:       return "Solid"
        case .building:    return "Building"
        case .calibrating: return "Calibrating"
        case .live:        return "Live"
        }
    }
    var pulsing: Bool { self == .live }
}

/// The score-lifecycle chip: dot + hue@.12 fill + hue@.32 border + hue text. LIVE
/// pulses its dot. `text` overrides the default state label (e.g. "Building — 2 of 4").
public struct ScoreStatePill: View {
    public var state: ScoreState
    public var text: LocalizedStringKey?
    public init(_ state: ScoreState, text: LocalizedStringKey? = nil) {
        self.state = state; self.text = text
    }
    public var body: some View {
        let hue = state.color
        return HStack(spacing: 6) {
            PulseDot(color: hue, pulsing: state.pulsing, size: 7)
            Text(text ?? state.label)
                .font(StrandFont.overline)
                .tracking(0.4)
                .foregroundStyle(hue)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(hue.opacity(0.12)))
        .overlay(Capsule(style: .continuous).stroke(hue.opacity(0.32), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? state.label)
    }
}

/// A small dot with an optional breathing pulse halo (LIVE). Honours Reduce Motion.
/// Local to the score pill so it doesn't disturb StatePill.swift's ConnectionDot.
private struct PulseDot: View {
    var color: Color
    var pulsing: Bool
    var size: CGFloat
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 2.4 : 1.0)
                    .opacity(animate ? 0.0 : 0.5)
                    .additiveBloom()
            }
            Circle().fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.8), radius: pulsing ? 4 : 2)
        }
        .frame(width: size, height: size)
        .onAppear { if pulsing && !reduceMotion { animate = true } }
        .animation(pulsing && !reduceMotion ? StrandMotion.breathe : nil, value: animate)
        .accessibilityHidden(true)
    }
}
