import Foundation
import WhoopStore

// MARK: - MoodStore
//
// Daily mood check-ins for the "Mind" section (design:
// 2026-06-12-noop-mind-mental-health-design.md, Phase 1b).
//
// Storage mirrors the native-journal pattern (Repository.journalDeviceId): mood
// lives in the existing metric-series tall table under a DEDICATED source id, so
// a WHOOP CSV re-import or Apple Health import can never clobber or clear the
// user's check-ins — the two streams stay independent. One scalar per LOCAL day
// (key "mood", value 1–5); the table's (deviceId, day, key) upsert makes an edit
// a plain overwrite, so "once a day, editable" needs no extra bookkeeping.
//
// Fully offline and opt-in by action: a row exists only when the user taps a face.

enum MoodStore {
    /// Dedicated source id for native mood rows (mirrors `Repository.journalDeviceId`
    /// — imports write under their own device ids and can never touch this one).
    static let moodDeviceId = "noop-mood"

    /// metricSeries key for the daily 1–5 mood scalar.
    static let moodKey = "mood"

    /// The check-in scale: 1 (lowest) … 5 (highest).
    static let scale: ClosedRange<Int> = 1...5

    /// Face glyph for a stored 1–5 value (clamps out-of-range defensively).
    static func face(for value: Int) -> String {
        switch value {
        case ...1: return "😞"
        case 2:    return "😕"
        case 3:    return "😐"
        case 4:    return "🙂"
        default:   return "😄"
        }
    }

    /// Neutral, non-clinical word for a stored 1–5 value — never a verdict.
    static func label(for value: Int) -> String {
        switch value {
        case ...1: return String(localized: "Rough")
        case 2:    return String(localized: "Low")
        case 3:    return String(localized: "Okay")
        case 4:    return String(localized: "Good")
        default:   return String(localized: "Great")
        }
    }
}

// MARK: - Persistence (Repository extension)

extension Repository {

    /// Full mood series (day "yyyy-MM-dd", value 1–5), oldest→newest. One row per
    /// local day by construction (the tall table's primary key dedupes).
    func moodSeries(days: Int = 4000) async -> [(day: String, value: Double)] {
        await series(key: MoodStore.moodKey, source: MoodStore.moodDeviceId, days: days)
    }

    /// The stored mood for one local day, nil if not checked in yet.
    func mood(day: String) async -> Int? {
        guard let store = await storeHandle() else { return nil }
        let pts = (try? await store.metricSeries(deviceId: MoodStore.moodDeviceId,
                                                 key: MoodStore.moodKey,
                                                 from: day, to: day)) ?? []
        return pts.last.map { Int($0.value.rounded()) }
    }

    /// Save (or overwrite) the day's mood. One row per local day — the upsert's
    /// (deviceId, day, key) conflict target makes an edit replace the earlier tap.
    func saveMood(day: String, value: Int) async {
        guard MoodStore.scale.contains(value),
              let store = await storeHandle() else { return }
        _ = try? await store.upsertMetricSeries(
            [MetricPoint(day: day, key: MoodStore.moodKey, value: Double(value))],
            deviceId: MoodStore.moodDeviceId)
    }
}
