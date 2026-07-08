#if !os(watchOS)
// The watch never draws the hypnogram (uses .onContinuousHover + ChartHover helpers, unavailable
// on watchOS); excluded there, iOS/macOS unchanged.
import SwiftUI

// MARK: - Hypnogram (§9.4 Sleep)
//
// A sleep-stage horizontal banded timeline. Each interval is drawn as a band at
// the height of its stage (awake top → deep bottom), colored per §9.1 with the
// Titanium & Gold sleep tokens — awake pale slate, light blue (#4A90E2), deep
// blue (#2F6FCB), REM bright blue (#6FA8E8) — so the four stages stay clearly
// distinguishable (fixes #345). Adjacent intervals are connected by vertical
// risers so the trace reads as one continuous "staircase".

/// A single stage interval. `start`/`end` are seconds from the start of the night.
public struct SleepInterval: Identifiable, Sendable {
    public var stage: SleepStage
    public var start: TimeInterval
    public var end: TimeInterval

    /// Stable, CONTENT-derived identity (stage + start + end) rather than a random `UUID()`.
    /// A fresh UUID per value defeated SwiftUI's `ForEach` diffing — every body eval re-identified
    /// all bands as brand-new, so the whole hypnogram rebuilt on each hover/diff. Intervals are
    /// non-overlapping with distinct starts within a night, so this composite is unique and stable.
    public var id: String { "\(stage.rawValue)|\(start)|\(end)" }

    public init(stage: SleepStage, start: TimeInterval, end: TimeInterval) {
        self.stage = stage
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }
}

public struct Hypnogram: View {

    public var intervals: [SleepInterval]
    /// Height of the plotting band.
    public var height: CGFloat
    /// Whether to draw the stage labels down the left edge.
    public var showsStageAxis: Bool
    /// Whether hovering a stage band highlights it and shows a tooltip
    /// (stage name, clock start–end, duration). Defaults on.
    public var showsHover: Bool
    /// Optional wall-clock time the night began. When set, the tooltip shows
    /// real clock times (e.g. "23:42–00:04"); otherwise it shows elapsed time
    /// from the start of the night (e.g. "0:06–0:28").
    public var nightStart: Date?
    /// Whether to anchor the timeline with an x time axis (onset · midpoint · wake
    /// hairlines + clock labels). Needs `nightStart`. Defaults off so existing
    /// callers are unchanged.
    public var showsTimeAxis: Bool

    public init(
        intervals: [SleepInterval],
        height: CGFloat = 180,
        showsStageAxis: Bool = true,
        showsHover: Bool = true,
        nightStart: Date? = nil,
        showsTimeAxis: Bool = false
    ) {
        self.intervals = intervals.sorted { $0.start < $1.start }
        self.height = height
        self.showsStageAxis = showsStageAxis
        self.showsHover = showsHover
        self.nightStart = nightStart
        self.showsTimeAxis = showsTimeAxis
    }

    /// Index of the hovered interval, or nil.
    @State private var hoverIndex: Int? = nil

    private static let clockFormatter: DateFormatter = {
        // "jmm" respects the device's 12-/24-hour setting (#337) rather than forcing 24-hour.
        let f = DateFormatter(); f.locale = Locale.current; f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()

    /// Format a seconds-from-origin offset either as wall-clock (if nightStart
    /// is set) or as elapsed H:MM from the start of the night.
    private func timeLabel(_ secondsFromOrigin: TimeInterval) -> String {
        if let nightStart {
            let d = nightStart.addingTimeInterval(secondsFromOrigin - origin)
            return Hypnogram.clockFormatter.string(from: d)
        }
        let total = Int((secondsFromOrigin - origin).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        return String(format: "%d:%02d", h, m)
    }

    private var span: TimeInterval {
        guard let first = intervals.first, let last = intervals.max(by: { $0.end < $1.end }) else { return 1 }
        return max(1, last.end - first.start)
    }
    private var origin: TimeInterval { intervals.first?.start ?? 0 }

    /// ONE spoken summary of the whole night for VoiceOver: total time in each stage. Replaces the old
    /// per-band accessibility layer (which emitted one element PER interval — O(intervals), a heavy
    /// semantics subtree the Compose/AppKit accessibility walk re-copied on every scroll, a contributor
    /// to the #707 OOM). Collapsing to one node keeps a clear screen-reader read-out at O(1) node cost.
    /// e.g. "Sleep stages, 2 hours deep, 1 hour 30 minutes REM, 3 hours light, 20 minutes awake".
    private var axSummary: String {
        guard !intervals.isEmpty else { return String(localized: "Sleep stages, no data", bundle: .module) }
        // Sum duration per stage in the natural read order (deep · REM · light · awake), naming only the
        // stages that actually occur so a night with no awake time doesn't read "0 minutes awake".
        var parts: [String] = []
        for stage in [SleepStage.deep, .rem, .light, .awake] {
            let total = intervals.filter { $0.stage == stage }.reduce(0.0) { $0 + $1.duration }
            if total > 0 { parts.append("\(Hypnogram.durationPhrase(total)) \(stage.label.lowercased())") }
        }
        return parts.isEmpty ? String(localized: "Sleep stages, no data", bundle: .module)
                             : String(localized: "Sleep stages, \(parts.joined(separator: ", "))", bundle: .module)
    }

    /// A spoken duration phrase ("2 hours 5 minutes", "45 minutes", "1 hour") for a seconds interval.
    private static func durationPhrase(_ seconds: TimeInterval) -> String {
        let total = Int((seconds / 60).rounded())   // whole minutes
        let h = total / 60
        let m = total % 60
        // Whole-phrase per unit (no "s"-suffix stitching) so each key can carry its own plural rule.
        func hours(_ n: Int) -> String { n == 1 ? String(localized: "1 hour", bundle: .module) : String(localized: "\(n) hours", bundle: .module) }
        func minutes(_ n: Int) -> String { n == 1 ? String(localized: "1 minute", bundle: .module) : String(localized: "\(n) minutes", bundle: .module) }
        if h > 0 && m > 0 { return "\(hours(h)) \(minutes(m))" }
        if h > 0 { return hours(h) }
        return minutes(max(m, 1))
    }

    // 4 stage rows; awake = rank 0 (top), deep = rank 3 (bottom).
    private let rowCount = 4

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsStageAxis { axis }
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack {
                        // STATIC LAYER: baselines + time-axis hairlines + risers + the stage bands.
                        // These rebuild only when intervals/size/hover change, so flatten them into ONE
                        // cached GPU raster via .drawingGroup() — the bands are flat solid pills (no
                        // blur), so the raster is pixel-identical. The hover crosshair/ring/tooltip stay
                        // OUTSIDE this group (below). drawingGroup() strips child accessibility elements,
                        // and VoiceOver is served by ONE collapsed element on the plot (see `axSummary`
                        // applied below) — so the bands raster cheaply AND the accessibility walk never
                        // copies a per-band subtree (the old O(intervals) layer was a #707 contributor).
                        ZStack {
                            // faint baselines per stage row
                            ForEach(0..<rowCount, id: \.self) { rank in
                                let y = rowY(rank, in: geo.size.height)
                                Path { p in
                                    p.move(to: CGPoint(x: 0, y: y))
                                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                                }
                                .stroke(StrandPalette.hairline.opacity(0.4), lineWidth: 1)
                            }

                            // time-axis vertical hairlines: onset · midpoint · wake
                            if showsTimeAxis, nightStart != nil {
                                ForEach([0.0, 0.5, 1.0], id: \.self) { frac in
                                    let x = geo.size.width * frac
                                    Path { p in
                                        p.move(to: CGPoint(x: x, y: 0))
                                        p.addLine(to: CGPoint(x: x, y: geo.size.height))
                                    }
                                    .stroke(StrandPalette.hairline.opacity(0.4), lineWidth: 1)
                                }
                            }

                            // connecting risers
                            risers(in: geo.size)

                            // stage bands (visual only — a11y is the single collapsed plot summary below)
                            ForEach(Array(intervals.enumerated()), id: \.element.id) { idx, interval in
                                let rect = bandRect(for: interval, in: geo.size)
                                let color = StrandPalette.sleepStageColor(interval.stage)
                                let dimmed = hoverIndex != nil && hoverIndex != idx
                                // Design Reset (WHOOP): NO REM bloom — every stage band is a flat, crisp
                                // solid pill; fill-contrast (not a glow) separates the four stages.
                                RoundedRectangle(cornerRadius: rect.height / 2)
                                    .fill(color)
                                    .frame(width: rect.width, height: rect.height)
                                    .opacity(dimmed ? 0.45 : 1.0)
                                    .position(x: rect.midX, y: rect.midY)
                            }
                        }
                        // NO .drawingGroup() — flat solid pills are cheap to draw inline; the per-instance
                        // offscreen flatten was part of the v7.0.2 lag regression. The #707 accessibility
                        // collapse is served by `.accessibilityHidden(true)` below + the single plot summary.
                        .accessibilityHidden(true)

                        // Hover affordance: crosshair, band highlight ring, tooltip.
                        if showsHover, let idx = hoverIndex, idx < intervals.count {
                            let interval = intervals[idx]
                            let rect = bandRect(for: interval, in: geo.size)
                            let color = StrandPalette.sleepStageColor(interval.stage)
                            // vertical crosshair across the full height at band centre
                            CrosshairRule(x: rect.midX, height: geo.size.height)
                            // ring around the hovered band
                            RoundedRectangle(cornerRadius: (rect.height + 6) / 2)
                                .stroke(StrandPalette.hairlineStrong, lineWidth: 1.5)
                                .frame(width: rect.width + 6, height: rect.height + 6)
                                .position(x: rect.midX, y: rect.midY)
                            PositionedTooltip(
                                anchor: CGPoint(x: rect.midX, y: rect.midY),
                                container: geo.size,
                                tooltip: ChartTooltip(
                                    value: interval.stage.label,
                                    label: "\(timeLabel(interval.start))-\(timeLabel(interval.end)) · \(Int((interval.duration / 60).rounded()))m",
                                    accent: color
                                )
                            )
                        }
                    }
                    .animation(StrandMotion.fade, value: hoverIndex)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard showsHover else { return }
                        switch phase {
                        case .active(let location):
                            hoverIndex = intervalIndex(atX: location.x, in: geo.size)
                        case .ended:
                            hoverIndex = nil
                        }
                    }
                    // ONE collapsed VoiceOver element for the whole hypnogram (per-stage totals), instead
                    // of the old O(intervals) per-band layer the accessibility walk re-copied each scroll
                    // frame (#707). The visual bands already live in a `.drawingGroup()` marked
                    // `accessibilityHidden`, so this single summary is the only node the chart contributes.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(axSummary))
                }
                .frame(height: height)

                // x time axis: onset · midpoint · wake clock labels under the plot
                if showsTimeAxis, nightStart != nil {
                    HStack(spacing: 0) {
                        Text(timeLabel(origin)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(timeLabel(origin + span / 2)).frame(maxWidth: .infinity, alignment: .center)
                        Text(timeLabel(origin + span)).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    /// The interval whose horizontal span contains a local x, or the nearest.
    private func intervalIndex(atX x: CGFloat, in size: CGSize) -> Int? {
        guard !intervals.isEmpty, size.width > 0 else { return nil }
        let t = origin + Double(x / size.width) * span
        // First try an exact containment hit.
        for (i, iv) in intervals.enumerated() where t >= iv.start && t <= iv.end {
            return i
        }
        // Otherwise snap to the nearest interval by centre time.
        return intervals.enumerated().min(by: { a, b in
            abs(midTime(a.element) - t) < abs(midTime(b.element) - t)
        })?.offset
    }

    private func midTime(_ iv: SleepInterval) -> TimeInterval { (iv.start + iv.end) / 2 }

    // MARK: Axis

    private var axis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(stagesTopToBottom, id: \.self) { stage in
                Text(stage.label)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: 44, height: height)
    }

    private var stagesTopToBottom: [SleepStage] {
        [.awake, .rem, .light, .deep]
    }

    // MARK: Geometry

    private func rowY(_ rank: Int, in totalHeight: CGFloat) -> CGFloat {
        let usable = totalHeight
        let step = usable / CGFloat(rowCount)
        return step * (CGFloat(rank) + 0.5)
    }

    private func bandRect(for interval: SleepInterval, in size: CGSize) -> CGRect {
        let x0 = CGFloat((interval.start - origin) / span) * size.width
        let x1 = CGFloat((interval.end - origin) / span) * size.width
        // Row-proportional thickness (floored) so bands fill the tall row gaps.
        let rowStep = size.height / CGFloat(rowCount)
        let thickness = max(NoopMetrics.hypnogramBandMinThickness, rowStep * 0.40)
        // Floor the WIDTH at the thickness and centre the band on its interval, so a brief stage —
        // especially a short Awake blip — reads as a rounded pill/dot rather than a thin glitch tick.
        let mid = (x0 + x1) / 2
        let width = max(thickness, x1 - x0)
        let y = rowY(interval.stage.bandRank, in: size.height)
        return CGRect(x: mid - width / 2, y: y - thickness / 2, width: width, height: thickness)
    }

    private func risers(in size: CGSize) -> some View {
        Path { p in
            for i in 0..<(intervals.count - (intervals.isEmpty ? 0 : 1)) {
                let a = intervals[i]
                let b = intervals[i + 1]
                let x = CGFloat((b.start - origin) / span) * size.width
                let ya = rowY(a.stage.bandRank, in: size.height)
                let yb = rowY(b.stage.bandRank, in: size.height)
                p.move(to: CGPoint(x: x, y: ya))
                p.addLine(to: CGPoint(x: x, y: yb))
            }
        }
        .stroke(StrandPalette.textTertiary.opacity(0.5), lineWidth: 2)
    }
}

#if DEBUG
private func sampleNight() -> [SleepInterval] {
    // ~7.5h night, seconds.
    var t: TimeInterval = 0
    func add(_ stage: SleepStage, _ minutes: Double) -> SleepInterval {
        let s = SleepInterval(stage: stage, start: t, end: t + minutes * 60)
        t += minutes * 60
        return s
    }
    return [
        add(.awake, 6),
        add(.light, 22),
        add(.deep, 38),
        add(.light, 18),
        add(.rem, 24),
        add(.light, 14),
        add(.deep, 30),
        add(.rem, 28),
        add(.light, 20),
        add(.awake, 4),
        add(.rem, 32),
        add(.light, 26),
        add(.awake, 8),
    ]
}

#Preview("Hypnogram") {
    let start = Calendar.current.date(bySettingHour: 23, minute: 18, second: 0, of: Date())
    return VStack(alignment: .leading, spacing: 12) {
        Text("Last night").strandOverline()
        Text("Hover a band: stage name, clock start–end and duration.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        Hypnogram(intervals: sampleNight(), height: 200, nightStart: start)
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
