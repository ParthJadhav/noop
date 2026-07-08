#if os(iOS)
import Foundation
import WidgetKit

extension WidgetSnapshot {
    /// Build a glance snapshot from the live app state and publish it to the shared App Group, then
    /// ask WidgetKit to refresh. Called when the app becomes active and after a Health sync.
    ///
    /// `async` because the Rest score (#446) lives in a computed metric series, not a `DailyMetric`
    /// column, so it needs an `exploreSeries` read. The sole caller already runs inside a `Task`, so it
    /// just gains an `await`. Charge / Effort / HRV / Resting HR all read synchronously off the SAME
    /// anchor day, so the richer fields and the headline never disagree about which day they describe.
    ///
    /// #911: the anchor is resolved the way Today resolves it (the current LOGICAL local day, `Date()`
    /// read here so the day rolls live as the extension republishes), NOT "the most recent day with any
    /// recovery score". The old anchor drifted around the day rollover: the new logical day exists but
    /// isn't scored yet, so `days.last(where: recovery != nil)` still pointed at yesterday's scored row
    /// and the widget showed the older day while Today had already moved on. We now anchor on today's
    /// row and, only when today isn't scored yet, carry over the last STRICTLY-PRIOR scored day for the
    /// recovery-derived fields (the same carry-over Today does), so the widget never blanks right after
    /// the rollover yet always describes today.
    @MainActor
    static func publish(from model: AppModel) async {
        let days = model.repo.days
        let now = Date()
        // The recovery-derived anchor: today's row when it's scored, else the freshest STRICTLY-PRIOR
        // scored day carried over. Resolved through the SHARED `Repository.widgetAnchor`, the ONE selector
        // the watch snapshot and the iOS Live Activity now also use, so all four surfaces describe the same
        // day (the #911 fix; see `Repository.widgetAnchor` for the rollover-drift rationale, the #304
        // pre-04:00 carve-out and the #547 future-day guard it folds in). The `$0.day < carriedKey` bound
        // inside the helper (matching `TodayView.selectedDayKey`) means a stale scored row can never
        // re-surface AS today.
        let day = Repository.widgetAnchor(days: days, now: now)
        // Rest (sleep_performance) for that same anchor day. exploreSeries merges imported + on-device,
        // exactly like the Today Rest tile. The tail fallback (restSeries.last) is ONLY valid when the
        // anchor day IS the local today: early in a fresh day today's Rest row may not exist yet, so we
        // borrow the latest value. For an anchor that is NOT today, borrowing the tail would surface a
        // DIFFERENT day's Rest as this day's (the cross-day bug), so we leave it nil. Mirrors TodayView's
        // `restByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? restSeries.last?.value : nil)` and the
        // matching guard in WatchSessionBridge.
        var restScore: Double?
        if let day {
            let restSeries = await model.repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            let anchorIsToday = day.day == Repository.localDayKey(now)
            restScore = restByDay[day.day] ?? (anchorIsToday ? restSeries.last?.value : nil)
        }
        let snap = WidgetSnapshot(
            recovery: day?.recovery.map { Int($0.rounded()) },
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct.map { Int($0.rounded()) },
            bonded: model.live.bonded,
            updated: Date(),
            // Effort is stored on NOOP's 0–100 axis (the same value the Today Effort tile reads), so it
            // publishes as a whole number without the WHOOP-0–21 toggle the main app applies — the widget
            // extension can't reach UnitFormatter/UnitPrefs, and 0–100 is the default scale.
            effort: day?.strain.map { Int($0.rounded()) },
            rest: restScore.map { Int($0.rounded()) },
            hrv: day?.avgHrv.map { Int($0.rounded()) },
            restingHr: day?.restingHr
        )
        snap.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
