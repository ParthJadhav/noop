#if os(iOS)
import Foundation
import WatchConnectivity
import StrandDesign
import WhoopStore   // DailyMetric (the anchor row's recovery / strain / sleep fields)

/// The PHONE side of the watch link (M3). The iPhone is the brain: M1 computes Charge / Effort / Rest
/// with confidence + provenance. This bridge takes the latest computed scores, builds a
/// `WatchScoreSnapshot` (the one shared Codable type, defined in StrandDesign so both sides agree on
/// the wire shape), and pushes it to the watch over WatchConnectivity.
///
/// Transport choice: `updateApplicationContext` (latest-state semantics, no queue). The watch only ever
/// wants the most recent snapshot, so we never want a backlog of `transferUserInfo` messages piling up
/// while the watch is off the wrist. Every dashboard refresh overwrites the single context.
///
/// It also writes the same snapshot into the shared app group's UserDefaults (`latestWatchSnapshot`),
/// so a freshly launched watch app + its complication read the last known value immediately even before
/// the next live push lands.
///
/// The honesty rule carries through unchanged: a calibrating score is sent as `nil` + its Calibrating
/// flag true, never a fabricated number. The watch renders "needs more data" for it.
@MainActor
final class WatchSessionBridge: NSObject, ObservableObject {

    /// The most recent snapshot we built + sent, surfaced for debug / a Settings "watch sync" readout.
    /// Also one half of the push gate below: a rebuilt snapshot whose headline values match this one is
    /// not worth a budgeted transfer, so `pushLatest` skips it.
    @Published private(set) var lastSent: WatchScoreSnapshot?
    /// When the last snapshot was actually pushed, the other half of the push gate. nil until the first
    /// push of this process, which therefore always passes the spacing check.
    private var lastPushedAt: Date?
    /// Minimum spacing between pushes (30 minutes). Complication/context transfers ride a system budget
    /// (~50/day for complication updates), so `pushLatest` never sends more often than this, and only
    /// when the headline values actually changed. BOTH checks must pass; see `shouldPush`.
    static let minPushInterval: TimeInterval = 30 * 60
    /// Whether a watch is currently paired + has the NOOP watch app installed + is reachable enough to
    /// receive context. Application context still queues for delivery when the watch is briefly away, so
    /// this is informational, not a gate on sending.
    @Published private(set) var isWatchReachable = false

    private let session: WCSession?

    override init() {
        // WCSession is only meaningful where the framework is supported (a real device, not every
        // simulator combination). When unsupported we keep a live object that simply no-ops every send,
        // so callers never need to branch.
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    /// Activate the session. Safe to call more than once (WCSession ignores a redundant activate). The
    /// app calls this once at startup, alongside the other session-scoped services.
    func activate() {
        guard let session else { return }
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        }
    }

    // MARK: - Sending

    /// Build a snapshot from the latest computed scores + their confidence and push it to the watch.
    /// Call this whenever the dashboard refreshes (the same trigger that republishes the Home-screen
    /// widget). It reads the SAME most-recent scored day the widget anchors on, so the wrist, the widget
    /// and Today never disagree about which day they describe.
    ///
    /// SELF-THROTTLED (the watch budget gate): callers may invoke this as often as they like, the push
    /// only goes out when `shouldPush` passes, at most once per `minPushInterval` AND only when the
    /// snapshot's headline values differ from the last push. A skipped snapshot is not lost: the next
    /// trigger (a refreshSeq bump, a foreground, a launch) rebuilds it fresh off the same model.
    ///
    /// `async` because Rest (sleep_performance) lives in a computed metric series rather than a
    /// `DailyMetric` column, so it needs an `exploreSeries` read (mirrors `WidgetSnapshot.publish`).
    func sendLatest(from model: AppModel) async {
        let snap = await Self.buildSnapshot(from: model)
        // A contentless snapshot (a cold launch races the first repo refresh, so `days` is still empty)
        // must NOT push: it would stomp the watch's last REAL data with the empty state AND burn the
        // 30-minute spacing gate, locking out the genuine snapshot that lands seconds later. Skip
        // without touching lastPushedAt/lastSent, so the first real snapshot passes the gate untouched.
        let contentless = snap.scoreDay == nil && snap.charge == nil && snap.effort == nil
            && snap.rest == nil && snap.sleepSummary.isEmpty
        if contentless { return }
        let now = Date()
        guard shouldPush(snap, now: now) else { return }
        lastPushedAt = now
        send(snap)
    }

    /// Build the latest snapshot off `model` and push it to the watch. The entrypoint the iOS app entry
    /// calls from the SAME refresh that republishes the Home-screen widget (scenePhase active, after a
    /// Health sync, and on an active-phase refreshSeq bump), so the wrist updates in lockstep with the
    /// widget instead of only ever showing placeholder data. Thin alias over `sendLatest` and therefore
    /// self-throttled the same way; named for the app-entry call site to read clearly.
    func pushLatest(from model: AppModel) async {
        await sendLatest(from: model)
    }

    /// The budget gate: complication/context transfers share a ~50/day system budget, so a push must
    /// pass BOTH checks. (1) Spacing: at least `minPushInterval` since the last actual push (nil = never
    /// pushed this process, passes). (2) Substance: the snapshot's HEADLINE values differ from the last
    /// pushed one, so an unchanged dashboard never burns a transfer re-stating the same scores.
    private func shouldPush(_ snap: WatchScoreSnapshot, now: Date) -> Bool {
        if let at = lastPushedAt, now.timeIntervalSince(at) < Self.minPushInterval { return false }
        return Self.headlineChanged(from: lastSent, to: snap)
    }

    /// Whether the headline content of `next` differs from the last-pushed snapshot. Headline = the
    /// scores (with their calibrating flags), the sleep summary line, and the day the scores are ABOUT.
    /// `hr` and `asOf` are deliberately NOT headline: hr ticks ~1 Hz and `asOf` differs on every build,
    /// so counting either as "changed" would defeat the dedup and re-send identical scores all day.
    /// nil `last` (nothing pushed yet) always counts as changed.
    static func headlineChanged(from last: WatchScoreSnapshot?, to next: WatchScoreSnapshot) -> Bool {
        guard let last else { return true }
        return last.charge != next.charge
            || last.chargeCalibrating != next.chargeCalibrating
            || last.effort != next.effort
            || last.effortCalibrating != next.effortCalibrating
            || last.rest != next.rest
            || last.restCalibrating != next.restCalibrating
            || last.sleepSummary != next.sleepSummary
            || last.scoreDay != next.scoreDay
    }

    /// Build the snapshot off the app state. Pure read; no side effects. Split out so the wiring is easy
    /// to follow and the calibrating logic sits in one place.
    static func buildSnapshot(from model: AppModel) async -> WatchScoreSnapshot {
        // #911: anchor the way Today does, through the SHARED `Repository.widgetAnchor` the Home/Lock
        // widget and the iOS Live Activity now also use, so the wrist, the widget, the Live Activity and
        // Today always describe the same day. `Date()` is read here so the day rolls live as the phone
        // republishes; the helper folds in the #304 pre-04:00 carve-out and the #547 future-day guard, and
        // anchors on today's row (not "the most recent day with any recovery score") so it can't drift
        // around the rollover. When today isn't scored yet it carries over the last STRICTLY-PRIOR scored
        // day for the recovery side.
        let days = model.repo.days
        let now = Date()
        let day = Repository.widgetAnchor(days: days, now: now)

        // Rest (sleep_performance) for that same anchor day. exploreSeries merges imported + on-device,
        // exactly like the Today Rest tile and the widget. The tail fallback (restSeries.last) is ONLY
        // valid when the anchor day IS the local today: early in a fresh day today's Rest row may not
        // exist yet, so we borrow the latest known value. For an anchor that is NOT today, borrowing the
        // tail would surface a DIFFERENT day's Rest as this day's without any cal marker (the cross-day
        // bug), so we leave it nil and let restCalibrating flag it honestly. #977: the tail is ALSO gated on
        // freshness now — a live 5.0 whose sleep never scores used to push a weeks-old Rest to the watch
        // forever; a stale tail falls through to nil so the watch shows its honest calibrating state. Mirrors
        // TodayView.freshRestScore.
        var restScore: Double?
        if let day {
            let restSeries = await model.repo.exploreSeries(key: "sleep_performance", source: model.deviceId)
            let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            let anchorIsToday = day.day == Repository.localDayKey(now)
            restScore = TodayView.freshRestScore(
                todayValue: restByDay[day.day], lastDay: restSeries.last?.day,
                lastValue: restSeries.last?.value, isTodaySelected: anchorIsToday, todayKey: day.day)
        }

        // The honesty rule: a missing number that is genuinely mid-calibration is flagged so the watch
        // shows a cal marker, not a dash that looks like an outage. We treat "no number for the anchor
        // day" as calibrating only when there is at least some day data to calibrate FROM. With no day
        // at all (a fresh, never-synced phone) the flags stay false and the watch shows its neutral
        // "open NOOP on your iPhone" empty state instead of implying calibration is underway.
        let hasAnyDay = day != nil
        let charge = day?.recovery
        let effort = day?.strain
        let rest = restScore

        let snap = WatchScoreSnapshot(
            charge: charge,
            chargeCalibrating: hasAnyDay && charge == nil,
            effort: effort,
            effortCalibrating: hasAnyDay && effort == nil,
            rest: rest,
            restCalibrating: hasAnyDay && rest == nil,
            hr: model.bpm ?? model.live.heartRate,
            sleepSummary: sleepSummary(for: day),
            asOf: Date(),
            // The day the scores are ABOUT (not when we built this), so the watch can label recency
            // honestly ("Yesterday") even when the build is fresh. nil when there's no anchor day at all.
            scoreDay: day?.day
        )
        return snap
    }

    /// A one line sleep summary for the glance, formatted on the phone (the watch never recomputes it).
    /// "7h 12m · 81%" when both are present; just the duration or just the efficiency when only one is;
    /// empty when neither is known (the watch then hides the line). Formatted through the app's string
    /// catalog ("%lldh %lldm" / "%lld%%", the same keys the Sleep screens use) so the wrist shows the
    /// phone's language, not hardcoded English.
    static func sleepSummary(for day: DailyMetric?) -> String {
        guard let day else { return "" }
        var parts: [String] = []
        if let mins = day.totalSleepMin, mins > 0 {
            let h = Int(mins) / 60
            let m = Int(mins) % 60
            parts.append(String(localized: "\(h)h \(m)m"))
        }
        if let eff = day.efficiency, eff > 0 {
            // efficiency is stored as a fraction in [0,1] in some paths and as a percent in others; the
            // cached DailyMetric carries the percent-style value the Today tile reads, so render it as a
            // whole percent and clamp defensively.
            let pct = eff <= 1.0 ? eff * 100 : eff
            parts.append(String(localized: "\(Int(pct.rounded()))%"))
        }
        return parts.joined(separator: " · ")
    }

    /// Push a snapshot to the watch via application context (latest-state) and mirror it into the shared
    /// app group so a cold-launched watch reads it at once. A no-op (bar the app-group write) when the
    /// session is unsupported or not yet activated.
    func send(_ snap: WatchScoreSnapshot) {
        lastSent = snap
        // Always mirror into the shared group: the watch app + complication read this on launch even if
        // the live context has not been delivered yet.
        snap.save()

        guard let session, session.activationState == .activated else { return }
        isWatchReachable = session.isReachable
        do {
            let data = try JSONEncoder().encode(snap)
            // updateApplicationContext replaces any previous context, so the watch always gets exactly
            // the latest snapshot and never a queued backlog.
            try session.updateApplicationContext([Self.contextKey: data])
        } catch {
            // A failed context update is non-fatal: the app-group mirror above still carries the latest
            // value, and the next dashboard refresh will try again.
        }
    }

    /// The key the encoded snapshot rides under inside the application context dictionary.
    static let contextKey = "snapshot"
    /// The message key the watch sends on launch to ask for the latest snapshot right now.
    static let requestLatestKey = "requestLatest"
}

// MARK: - WCSessionDelegate

extension WatchSessionBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isWatchReachable = session.isReachable
        }
    }

    // The watch can re-pair to a different phone; iOS requires both of these to be present, and a
    // re-activate so the link stays live for the new pairing.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isWatchReachable = session.isReachable
        }
    }

    /// The watch's "send me the latest" request on launch. We re-mirror the last snapshot into the
    /// shared app group and reply with it inline so the watch has a value the instant it asks. The
    /// reply also lets the watch confirm the link is live.
    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard message[Self.requestLatestKey] != nil else {
            replyHandler([:])
            return
        }
        // Read the last value we mirrored into the shared group and hand it straight back. Done off the
        // main actor since the request arrives on WC's queue; the app-group read is process-safe.
        if let snap = WatchScoreSnapshot.load(), let data = try? JSONEncoder().encode(snap) {
            replyHandler([Self.contextKey: data])
        } else {
            replyHandler([:])
        }
    }
}
#endif
