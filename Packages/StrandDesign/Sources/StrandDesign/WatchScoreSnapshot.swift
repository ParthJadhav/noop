import Foundation

/// The phone to watch payload. The iPhone is the brain (M1 computes Charge / Effort / Rest with
/// confidence + provenance); this is the small, honest snapshot it pushes over WatchConnectivity for
/// the watch app + its complication to DISPLAY. The watch never recomputes a score, it only renders
/// what arrived here.
///
/// It lives in StrandDesign so BOTH sides import one definition: the iOS `WatchSessionBridge` encodes
/// it, the watchOS app + complication decode it (read from the shared app group's UserDefaults under
/// `latestWatchSnapshot`). One type, one wire shape, so the glance and the complication can never
/// disagree about what the phone said.
///
/// The honesty rule carries through: a calibrating score is the number being `nil` AND the matching
/// `Calibrating` flag set true. The watch UI must render that as "needs more data" (a dash + a small
/// cal marker), NEVER a fabricated number. A score that simply has not been computed yet is also `nil`
/// but with its flag false (missing data, not mid-calibration) and reads as a plain dash.
public struct WatchScoreSnapshot: Codable, Equatable, Sendable {
    /// Charge (recovery), 0 to 100. `nil` when there is no earned number for the day.
    public var charge: Double?
    /// True when Charge is still calibrating (the baseline is not usable yet). When true, `charge` is
    /// `nil` and the watch shows a cal marker rather than a number.
    public var chargeCalibrating: Bool

    /// Effort (strain) on NOOP's 0 to 100 axis. `nil` when there is no usable HR window for the day.
    public var effort: Double?
    /// True when Effort is still calibrating. `effort` is `nil` while this is true.
    public var effortCalibrating: Bool

    /// Rest (sleep) composite, 0 to 100. `nil` when there is no matched in-bed session for the day.
    public var rest: Double?
    /// True when Rest is still calibrating. `rest` is `nil` while this is true.
    public var restCalibrating: Bool

    /// Most recent heart rate the phone knows about (bpm). The watch shows its OWN live HR off its
    /// sensor; this is just the last value the phone had, used as a fallback / sync indicator.
    public var hr: Int?

    /// A one line sleep summary for the glance (e.g. "7h 12m · 81% efficiency"), already formatted by
    /// the phone. Empty string when there is nothing to show.
    public var sleepSummary: String

    /// When the phone built this snapshot. The watch shows its age ("as of 2h ago") rather than
    /// implying the numbers are live.
    public var asOf: Date

    /// The anchor day these scores describe, as a "YYYY-MM-DD" local day key (nil when unknown). This is
    /// the day the numbers are ABOUT, which is not the same as `asOf` (when the phone built the snapshot):
    /// you can build a snapshot at 9am that still describes yesterday's scores until today's are computed.
    /// The watch prefers this for its recency label so it reads honestly ("Yesterday") even when the build
    /// is recent. Optional + decodes as nil when absent so older payloads on the wire stay compatible.
    public var scoreDay: String?

    public init(charge: Double?, chargeCalibrating: Bool,
                effort: Double?, effortCalibrating: Bool,
                rest: Double?, restCalibrating: Bool,
                hr: Int?, sleepSummary: String, asOf: Date,
                scoreDay: String? = nil) {
        self.charge = charge
        self.chargeCalibrating = chargeCalibrating
        self.effort = effort
        self.effortCalibrating = effortCalibrating
        self.rest = rest
        self.restCalibrating = restCalibrating
        self.hr = hr
        self.sleepSummary = sleepSummary
        self.asOf = asOf
        self.scoreDay = scoreDay
    }

    // MARK: - Shared app group transport
    //
    // The watch app + its complication read the latest snapshot from the shared app group's
    // UserDefaults under this key. The phone side writes the same key on its own UserDefaults view of
    // the group too (belt and braces alongside updateApplicationContext), so a freshly launched watch
    // reads the last known value immediately.

    /// The shared app group both the watch app and its complication read the snapshot from.
    public static let appGroupId = "group.com.noopapp.noop"
    /// The UserDefaults key the latest snapshot is stored under in the shared app group.
    public static let storageKey = "latestWatchSnapshot"

    /// A neutral placeholder for previews / a not-yet-synced watch. Everything calibrating + empty so
    /// nothing fake is ever drawn.
    public static var placeholder: WatchScoreSnapshot {
        WatchScoreSnapshot(charge: nil, chargeCalibrating: true,
                           effort: nil, effortCalibrating: true,
                           rest: nil, restCalibrating: true,
                           hr: nil, sleepSummary: "", asOf: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Freshness
    //
    // The phone is the only thing that computes scores; the watch just renders the last snapshot it has.
    // If the wrist hasn't seen the phone for a long stretch (off the charger, phone dead, app not opened),
    // the numbers it's holding can quietly go stale. These two helpers let the watch UI stay honest about
    // that: degrade a too-old snapshot to a dash, and always show a short recency label next to the rings.

    /// How old a snapshot may be before the watch should stop presenting it as the current day's scores.
    /// ~36h, not 24h: scores anchor on a logical day and Rest in particular lands the morning after, so a
    /// little past a full day is normal. Beyond this it's almost certainly a phone the watch lost touch with.
    private static let stalenessThreshold: TimeInterval = 36 * 3600

    /// True when this snapshot is too old to present as current. Callers degrade the rings + number to a
    /// dash (and lean on `freshnessText` to explain why) rather than drawing a confidently wrong figure.
    /// The placeholder (asOf at the epoch) always reads stale, which is what we want for a never-synced watch.
    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(asOf) > Self.stalenessThreshold
    }

    /// The semantic freshness buckets behind `freshnessText`. Display code that needs to REASON about
    /// recency (e.g. "the label adds nothing while the scores are current, hide it") goes through
    /// `isFreshToday`, which switches on this classification. It must never compare the localized
    /// display string ("Today" / "just now") instead: that reads fine in English and silently breaks
    /// in every translated language.
    private enum FreshnessKind {
        case today
        case yesterday
        case weekday(Date)
        case daysAgo(Int)
        case builtJustNow
        case builtMinutesAgo(Int)
        case builtHoursAgo(Int)
        case builtDaysAgo(Int)
    }

    /// Classify this snapshot's recency. Prefers `scoreDay` (the day the scores are ABOUT) when the
    /// phone supplied it, so the label can read "Today" / "Yesterday" / a weekday rather than implying
    /// live numbers. Falls back to the `asOf` build age for older payloads that predate `scoreDay`.
    private func freshnessKind(now: Date) -> FreshnessKind {
        let cal = Calendar.current

        // Preferred path: we know which day the scores describe. Compare day keys against "now" so the
        // label tracks the actual calendar day, not the build clock.
        if let scoreDay, let scored = Self.dayKeyFormatter.date(from: scoreDay) {
            if cal.isDateInToday(scored) { return .today }
            if cal.isDateInYesterday(scored) { return .yesterday }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: scored),
                                          to: cal.startOfDay(for: now)).day ?? 0
            // Within the last week a weekday name ("Mon") is the most readable; past that, a plain count.
            if days >= 2 && days <= 6 { return .weekday(scored) }
            return .daysAgo(max(days, 0))
        }

        // Fallback: no scoreDay (an older snapshot). Describe the build age of the snapshot itself.
        let age = now.timeIntervalSince(asOf)
        if age < 60 { return .builtJustNow }
        if age < 3600 { return .builtMinutesAgo(Int(age / 60)) }
        if age < 86_400 { return .builtHoursAgo(Int(age / 3600)) }
        return .builtDaysAgo(Int(age / 86_400))
    }

    /// A short, honest recency label for the glance + complication ("Today" / "Yesterday" / "2h ago").
    /// Rendered off `freshnessKind` so the words and the semantics (`isFreshToday`) can never drift.
    public func freshnessText(now: Date = Date()) -> String {
        switch freshnessKind(now: now) {
        case .today:                  return String(localized: "Today", bundle: .module)
        case .yesterday:              return String(localized: "Yesterday", bundle: .module)
        case .weekday(let scored):
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return f.string(from: scored)
        case .daysAgo(let days):      return String(localized: "\(days) days ago", bundle: .module)
        case .builtJustNow:           return String(localized: "just now", bundle: .module)
        case .builtMinutesAgo(let m): return String(localized: "\(m)m ago", bundle: .module)
        case .builtHoursAgo(let h):   return String(localized: "\(h)h ago", bundle: .module)
        case .builtDaysAgo(let d):    return String(localized: "\(d)d ago", bundle: .module)
        }
    }

    /// True when the scores read as CURRENT: they describe today's local day, or (for older payloads
    /// without `scoreDay`) the snapshot was built under a minute ago. This is the semantic twin of
    /// `freshnessText` returning "Today" / "just now", and it is what display code must key off when it
    /// appends the freshness label only where it adds information. Never compare the localized display
    /// text for that decision: it breaks the moment a string catalog translates "Today". Derived at
    /// read time from fields already on the wire (`scoreDay` + `asOf`), so the encoded payload is
    /// unchanged and a snapshot from an older phone build classifies exactly as before.
    public func isFreshToday(now: Date = Date()) -> Bool {
        switch freshnessKind(now: now) {
        case .today, .builtJustNow: return true
        default:                    return false
        }
    }

    /// Shared "YYYY-MM-DD" parser/formatter for `scoreDay`. Fixed locale + POSIX so it round-trips the
    /// phone's `Repository.localDayKey` keys identically regardless of the watch's region settings.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Decode the last snapshot the phone wrote into the shared app group, if any.
    public static func load(from defaults: UserDefaults? = UserDefaults(suiteName: appGroupId)) -> WatchScoreSnapshot? {
        guard let defaults,
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Persist this snapshot into the shared app group so the watch app + complication can read it.
    public func save(to defaults: UserDefaults? = UserDefaults(suiteName: WatchScoreSnapshot.appGroupId)) {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: WatchScoreSnapshot.storageKey)
    }
}
