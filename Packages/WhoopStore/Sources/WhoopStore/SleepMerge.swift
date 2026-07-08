import Foundation

/// Merge imported and on-device-computed sleep sessions for display and export.
public enum SleepMerge {
    /// Merge imported + computed sleep, preserving EVERY session.
    ///
    /// A day with two sessions (e.g. a main night and an afternoon nap, or two nights ending the same
    /// local day) must keep BOTH — the previous per-day dictionary overwrote on collision and silently
    /// dropped one (#715). Imported sessions take precedence per day: if any imported session ends on a
    /// given local day, the computed sessions for that day yield to it (the existing imported-over-computed
    /// rule); on days with no imported session the computed sessions stand. Result is sorted by start time.
    ///
    /// - Parameter endDay: maps a session to its canonical LOCAL end-day key (callers inject their
    ///   timezone-aware keyer so this stays pure and testable).
    public static func merge(imported: [CachedSleepSession],
                             computed: [CachedSleepSession],
                             endDay: (CachedSleepSession) -> String) -> [CachedSleepSession] {
        var importedDays = Set<String>()
        var out: [CachedSleepSession] = []
        out.reserveCapacity(imported.count + computed.count)
        for s in imported { importedDays.insert(endDay(s)); out.append(s) }
        for s in computed where !importedDays.contains(endDay(s)) { out.append(s) }
        return out.sorted { $0.startTs < $1.startTs }
    }
}
