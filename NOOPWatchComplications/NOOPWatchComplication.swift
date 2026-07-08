import WidgetKit
import SwiftUI
import StrandDesign

// MARK: - NOOP watch-face complication
//
// The headline feature of M3: Charge (recovery) on the wrist. The iPhone is the brain
// (M1 computes Charge / Effort / Rest with confidence + provenance); this complication ONLY
// displays the latest `WatchScoreSnapshot` the phone pushed into the shared app group. It never
// recomputes a score.
//
// The honesty rule carries through from M1: a CALIBRATING score has a nil number plus its
// Calibrating flag set, and we render a dash with a subtle "cal" marker, never a fabricated
// number. When there is no snapshot at all we show a NEUTRAL placeholder (a dash + the NOOP
// glyph), not a zero, so an empty face never reads as "your Charge is 0".
//
// Families: accessoryCircular (ring + number), accessoryCorner, accessoryInline (text), and
// accessoryRectangular (a compact card with all three scores).

// MARK: - Snapshot access
//
// We read the app group directly here rather than depending on a loader symbol from the bridge
// lane, so this extension only needs the shared `WatchScoreSnapshot` type from StrandDesign. The
// suite + key match the cross-lane contract: the phone-side bridge writes the latest snapshot to
// `group.com.noopapp.noop` under `latestWatchSnapshot`, and the watch app + this complication read
// it. The suite name is read from the extension's own Info.plist (AppGroupIdentifier) so it lives
// in one place, with the canonical group as a fallback.

enum WatchSnapshotAccess {
    // The app group is read from the extension's own Info.plist (AppGroupIdentifier) so the entitled
    // value wins, then falls back to the canonical group the contract pins. The storage KEY is the
    // shared one from StrandDesign so the writer and every reader can never desync on it.
    static let suiteName: String = {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? WatchScoreSnapshot.appGroupId
    }()

    static let storageKey = WatchScoreSnapshot.storageKey

    /// The last snapshot the phone pushed, or nil if nothing has synced yet.
    static func load() -> WatchScoreSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data) else { return nil }
        return snap
    }
}

// MARK: - Timeline

/// One timeline entry, backed by the latest snapshot (or nil when nothing has synced).
struct ChargeEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchScoreSnapshot?
}

struct ChargeProvider: TimelineProvider {
    /// A friendly stand-in for the gallery / first paint. Shows a real-looking Charge so the
    /// complication previews well, but it is never persisted and the live view falls back to the
    /// neutral placeholder when there is genuinely no snapshot.
    func placeholder(in context: Context) -> ChargeEntry {
        ChargeEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (ChargeEntry) -> Void) {
        // In the gallery (isPreview) show the friendly preview; on a real face show what synced.
        let snap = context.isPreview ? WatchScoreSnapshot.preview : WatchSnapshotAccess.load()
        completion(ChargeEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ChargeEntry>) -> Void) {
        let snap = WatchSnapshotAccess.load()
        // The phone forces a reload (WidgetCenter.reloadAllTimelines) whenever it pushes a fresh
        // snapshot, so this periodic refresh is just a backstop. Roughly every 30 minutes keeps the
        // "as of …" age honest without burning the watch's complication budget.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [ChargeEntry(date: Date(), snapshot: snap)], policy: .after(next)))
    }
}

// MARK: - Preview snapshot

private extension WatchScoreSnapshot {
    /// A representative snapshot for the widget gallery: a primed Charge, a mid Effort, a calibrating
    /// Rest (so the gallery also shows the cal marker), a live HR and a short sleep line.
    static var preview: WatchScoreSnapshot {
        WatchScoreSnapshot(
            charge: 74, chargeCalibrating: false,
            effort: 41, effortCalibrating: false,
            rest: nil, restCalibrating: true,
            hr: 58,
            sleepSummary: "7h 12m",
            asOf: Date()
        )
    }
}

// MARK: - Score read-out helpers
//
// One place decides how a (value, calibrating) pair renders, so the four family views can never
// disagree and the honesty rule is enforced once.

/// How a single score should be drawn: a real number, a calibrating dash, or simply absent.
private enum ScoreReadout {
    case value(Int)
    case calibrating
    case missing

    /// Map the snapshot's (optional number + Calibrating flag) into a readout. A calibrating score
    /// (number nil + flag true) is `.calibrating`; a present number is `.value`; everything else is
    /// `.missing`. We never invent a number for a calibrating score.
    init(value: Double?, calibrating: Bool) {
        if let v = value {
            self = .value(Int(v.rounded()))
        } else if calibrating {
            self = .calibrating
        } else {
            self = .missing
        }
    }

    /// The fraction (0...1) to fill a ring/gauge with. Calibrating + missing read as an empty track.
    var fraction: Double {
        if case let .value(v) = self { return min(max(Double(v) / 100.0, 0), 1) }
        return 0
    }

    /// The big number, or a dash for calibrating / missing.
    var numberText: String {
        if case let .value(v) = self { return "\(v)" }
        return "–"
    }
}

// MARK: - The complication view

struct NOOPChargeView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ChargeEntry

    // MARK: One shared staleness decision
    //
    // Every family routes through `isStale` so they stay consistent: a days-old snapshot must never
    // read as live in ANY family. When stale we collapse each score to the SAME calibrating dash the
    // missing/calibrating path already draws, rather than painting an old number. Mirrors how
    // ScoreReadout centralises the calibrating/missing call so the four views can never disagree.

    /// True when we have a snapshot but it is too old to present as current. nil snapshot is handled
    /// separately as the neutral placeholder, so this is purely about an aged-out real snapshot.
    private var isStale: Bool {
        guard let snap = entry.snapshot else { return false }
        return snap.isStale(now: entry.date)
    }

    /// Map one score, but force the calibrating dash when the whole snapshot is stale. Centralising it
    /// here means circular / corner / inline / rectangular all degrade identically.
    private func readout(_ value: Double?, _ calibrating: Bool) -> ScoreReadout {
        if isStale { return .calibrating }
        return ScoreReadout(value: value, calibrating: calibrating)
    }

    private var charge: ScoreReadout {
        readout(entry.snapshot?.charge, entry.snapshot?.chargeCalibrating ?? false)
    }
    private var effort: ScoreReadout {
        readout(entry.snapshot?.effort, entry.snapshot?.effortCalibrating ?? false)
    }
    private var rest: ScoreReadout {
        readout(entry.snapshot?.rest, entry.snapshot?.restCalibrating ?? false)
    }

    /// True when nothing has ever synced from the phone. Drives the neutral placeholder.
    private var noSnapshot: Bool { entry.snapshot == nil }

    /// The honest recency label for the families that have room for one, straight from the contract.
    private var freshness: String? {
        guard let snap = entry.snapshot else { return nil }
        return snap.freshnessText(now: entry.date)
    }

    /// True when the snapshot's scores read as current ("Today" / "just now"). The families below skip
    /// the recency label in that case because it adds no information next to a live-looking number.
    /// Decided by the SEMANTIC flag on the shared contract, never by comparing the localized display
    /// text `freshness` returns; a display-text comparison would silently stop matching in every
    /// language the string catalogs translate.
    private var isFreshToday: Bool {
        entry.snapshot?.isFreshToday(now: entry.date) ?? false
    }

    var body: some View {
        switch family {
        case .accessoryCircular:    circular
        case .accessoryCorner:      corner
        case .accessoryInline:      Text(inlineText)
        case .accessoryRectangular: rectangular
        default:                    circular
        }
    }

    // MARK: Charge tint
    //
    // Tinted to the Charge colour world only when we have a real number. A calibrating or missing
    // Charge stays neutral so the empty ring never borrows a "good"/"bad" colour it did not earn.

    private var chargeTint: Color {
        if case let .value(v) = charge { return StrandPalette.recoveryColor(Double(v)) }
        return StrandPalette.textTertiary
    }

    // MARK: accessoryCircular — a ring + the Charge number
    //
    // The clean NOOP ring, scaled to the watch face. WidgetKit tints accessory complications with the
    // face's vibrant colour by default; we use a Gauge so the system renders a crisp circular ring,
    // and tint it to the Charge colour where we have a real value. A small "cal" marker replaces the
    // number when Charge is calibrating.

    private var circular: some View {
        Gauge(value: charge.fraction, in: 0...1) {
            // The minimumValueLabel slot stays empty; the centre carries the read-out.
            EmptyView()
        } currentValueLabel: {
            VStack(spacing: 0) {
                Text(charge.numberText)
                    .font(StrandFont.rounded(15, weight: .semibold))
                    .minimumScaleFactor(0.6)
                if case .calibrating = charge {
                    calPip
                }
            }
        }
        .gaugeStyle(.accessoryCircular)
        .tint(chargeTint)
        // The curved label carries the recency so even the tiny circle is honest: "Charge · 2h ago"
        // when aging, plain "Charge" when fresh, a sync hint when nothing has synced.
        .widgetLabel(circularLabel)
        .widgetAccentable()
        .accessibilityLabel(accessibilityCharge)
    }

    /// The circular family's curved widgetLabel. Appends the freshness once a snapshot starts aging so
    /// the number above it is never read as live; stays "Charge" while it is fresh.
    private var circularLabel: String {
        guard let fresh = freshness else { return String(localized: "Charge") }
        if isStale { return String(localized: "Charge · \(fresh)") }
        // A current snapshot's label adds no information next to a live-looking ring, so keep it clean.
        if isFreshToday { return String(localized: "Charge") }
        return String(localized: "Charge · \(fresh)")
    }

    // MARK: accessoryCorner — number hugging the corner, "Charge" curved along the bezel

    private var corner: some View {
        Text(charge.numberText)
            .font(StrandFont.rounded(17, weight: .semibold))
            .foregroundStyle(chargeTint)
            .widgetAccentable()
            // The curved label rides the watch-face bezel. When calibrating we say so plainly rather
            // than leaving a bare dash with no context.
            .widgetLabel {
                Text(cornerLabel)
            }
            .accessibilityLabel(accessibilityCharge)
    }

    private var cornerLabel: String {
        switch charge {
        case .value:
            // Real number: ride the bezel with the recency so an aging score stays honest. A current
            // snapshot keeps the plain label (semantic flag, not a display-text comparison).
            guard let fresh = freshness, !isFreshToday else { return String(localized: "Charge") }
            return String(localized: "Charge · \(fresh)")
        case .calibrating:
            // When the dash is here because the whole snapshot went stale, say so plainly rather than
            // "cal" (which means "needs more data", a different thing).
            if isStale {
                let fresh = freshness ?? String(localized: "stale")
                return String(localized: "Charge · \(fresh)")
            }
            return String(localized: "Charge · cal")
        case .missing:
            return noSnapshot ? String(localized: "Open NOOP") : String(localized: "Charge")
        }
    }

    // MARK: accessoryInline — a single line of text along the top of the face

    private var inlineText: String {
        if noSnapshot { return String(localized: "NOOP · open on iPhone") }
        // When the snapshot has aged out we never print the old number; we say it is stale and how old.
        if isStale {
            let fresh = freshness ?? String(localized: "old")
            return String(localized: "Charge stale · \(fresh)")
        }
        switch charge {
        case .value(let v):
            // A fresh number reads as live, so append the recency once it starts to age.
            let suffix = inlineFreshnessSuffix
            if let hr = entry.snapshot?.hr { return String(localized: "Charge \(v) · \(hr) bpm\(suffix)") }
            return String(localized: "Charge \(v)\(suffix)")
        case .calibrating:
            return String(localized: "Charge calibrating")
        case .missing:
            return String(localized: "Charge –")
        }
    }

    /// " · 2h ago" appended to the inline line once a snapshot ages, empty while it is fresh so a live
    /// reading stays uncluttered. Keyed off the semantic flag, never the localized display text.
    private var inlineFreshnessSuffix: String {
        guard let fresh = freshness, !isFreshToday else { return "" }
        return " · \(fresh)"
    }

    // MARK: accessoryRectangular — a compact card showing all three scores
    //
    // The richest family: a small NOOP header line plus the Charge / Effort / Rest triplet, each a
    // number (or a dash + cal marker) over its label. This is the only place all three scores live, so
    // it doubles as the "everything at a glance" face.

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Header: the wordmark + the snapshot age (or a sync hint when empty).
            HStack(spacing: 4) {
                Text("NOOP")
                    .font(StrandFont.rounded(11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                Text(headerTrailing)
                    .font(.system(size: 10))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            // The three scores, equal-width.
            HStack(alignment: .top, spacing: 0) {
                scoreCell(String(localized: "Charge"), readout: charge, tint: chargeTint)
                scoreCell(String(localized: "Effort"), readout: effort, tint: effortTint)
                scoreCell(String(localized: "Rest"), readout: rest, tint: restTint)
            }
        }
        .widgetAccentable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRectangular)
    }

    /// The trailing header text: a sync hint when empty, otherwise the honest recency label so a stale
    /// snapshot reads as "Yesterday" / "2h ago" rather than implying it is live. The three cells below
    /// already collapse to the calibrating dash when stale, so the header and the numbers agree.
    private var headerTrailing: String {
        guard let snap = entry.snapshot else { return String(localized: "open iPhone") }
        return snap.freshnessText(now: entry.date)
    }

    /// One labelled score in the rectangular card. A real value tints to its colour world; a
    /// calibrating score shows a dash plus a tiny "cal" marker; missing shows a neutral dash.
    private func scoreCell(_ label: String, readout: ScoreReadout, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(readout.numberText)
                    .font(StrandFont.rounded(18, weight: .semibold))
                    .foregroundStyle(readoutIsValue(readout) ? tint : StrandPalette.textTertiary)
                    .minimumScaleFactor(0.7)
                if case .calibrating = readout {
                    Text("cal")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, 2)
                        .background(
                            Capsule().fill(StrandPalette.surfaceInset)
                        )
                }
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readoutIsValue(_ r: ScoreReadout) -> Bool {
        if case .value = r { return true }
        return false
    }

    // MARK: Effort / Rest tints (rectangular only)

    private var effortTint: Color {
        if case let .value(v) = effort { return StrandPalette.effortTint(fraction: Double(v) / 100) }
        return StrandPalette.textTertiary
    }
    private var restTint: Color {
        if case let .value(v) = rest { return StrandPalette.recoveryColor(Double(v)) }
        return StrandPalette.textTertiary
    }

    // MARK: The "cal" marker
    //
    // A subtle, lowercase "cal" pill. Small and tertiary so it reads as a status footnote, not an
    // alarm. This is what the honesty rule looks like on a tiny face: a dash plus this, never a number.

    private var calPip: some View {
        Text("cal")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: Accessibility

    private var accessibilityCharge: String {
        // A stale snapshot collapses to the calibrating dash visually, but for VoiceOver we say WHY it
        // is a dash plainly so it is never mistaken for "still calibrating".
        if isStale {
            let fresh = freshness ?? String(localized: "a while ago")
            return String(localized: "Charge out of date, last synced \(fresh). Open NOOP on iPhone.")
        }
        switch charge {
        case .value(let v):    return String(localized: "Charge \(v) out of 100")
        case .calibrating:     return String(localized: "Charge calibrating, needs more data")
        case .missing:         return noSnapshot ? String(localized: "No data, open NOOP on iPhone")
                                                 : String(localized: "Charge unavailable")
        }
    }

    private var accessibilityRectangular: String {
        if noSnapshot { return String(localized: "NOOP. No data yet, open NOOP on your iPhone to sync.") }
        if isStale {
            let fresh = freshness ?? String(localized: "a while ago")
            return String(localized: "NOOP. Scores out of date, last synced \(fresh). Open NOOP on iPhone to refresh.")
        }
        func phrase(_ label: String, _ r: ScoreReadout) -> String {
            switch r {
            case .value(let v):  return String(localized: "\(label) \(v)")
            case .calibrating:   return String(localized: "\(label) calibrating")
            case .missing:       return String(localized: "\(label) unavailable")
            }
        }
        let chargePhrase = phrase(String(localized: "Charge"), charge)
        let effortPhrase = phrase(String(localized: "Effort"), effort)
        let restPhrase = phrase(String(localized: "Rest"), rest)
        return String(localized: "NOOP. \(chargePhrase), \(effortPhrase), \(restPhrase).")
    }

    // Snapshot recency now comes straight from the shared contract (`freshnessText` / `isStale` on
    // WatchScoreSnapshot) so the watch app glance and this complication phrase age identically. The
    // old local ageString helper was retired with that move.
}

// MARK: - Widget declaration

struct NOOPChargeComplication: Widget {
    let kind = "NOOPChargeComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ChargeProvider()) { entry in
            NOOPChargeView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("NOOP Charge")
        .description("Your Charge (recovery) on the watch face, with Effort and Rest in the rectangular card.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}
