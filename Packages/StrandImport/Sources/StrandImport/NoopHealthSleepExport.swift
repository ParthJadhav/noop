import Foundation

// MARK: - Sleep → Apple Health export mapping (pure, platform-agnostic)
//
// The iOS `HealthKitBridge` write-back can mirror NOOP's strap-detected sleep into Apple Health as
// `sleepAnalysis` category samples. The *parsing* of a session's `stagesJSON` into a stage timeline
// is pure Foundation (no HealthKit), so it lives here in StrandImport where it compiles on every
// platform and can be unit-tested on the macOS test host. The bridge maps `NoopSleepStageKind`
// onto `HKCategoryValueSleepAnalysis`.

/// One sleep stage as NOOP records it, independent of HealthKit. `core` is Apple's name for what the
/// on-device stager calls "light"; `asleepUnspecified` is the whole-session fallback used when a
/// session carries no decodable stage timeline.
public enum NoopSleepStageKind: String, Sendable, Equatable, CaseIterable {
    case awake
    case core
    case deep
    case rem
    case asleepUnspecified
}

/// One absolute-time stage span. `start`/`end` are wall-clock dates (derived from the session's unix
/// timestamps), ready to hand to a health store as a sample interval.
public struct NoopSleepInterval: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let kind: NoopSleepStageKind
    public init(start: Date, end: Date, kind: NoopSleepStageKind) {
        self.start = start
        self.end = end
        self.kind = kind
    }
}

public enum NoopHealthSleepExport {

    /// Resolve a session's `stagesJSON` into absolute-time stage intervals suitable for writing to a
    /// health store.
    ///
    /// Two `stagesJSON` shapes exist in the store (see `SleepView`): the COMPUTED segment array
    /// `[{"start":epoch,"end":epoch,"stage":"wake"|"light"|"deep"|"rem"}]` carries a real timeline and
    /// maps 1:1 onto per-stage intervals; the IMPORTED minutes dict
    /// `{"light":..,"deep":..,"rem":..,"awake":..}` carries no timeline. When the segment array can't
    /// be decoded (nil / empty / the minutes-dict form), we fall back to a single
    /// `.asleepUnspecified` interval spanning `[sessionStart, sessionEnd]` so every night still lands
    /// in Apple Health rather than being silently dropped.
    ///
    /// Returns `[]` only when there is nothing writable at all — no decodable segments AND a
    /// degenerate span (`sessionEnd <= sessionStart`).
    public static func stageIntervals(stagesJSON: String?,
                                      sessionStart: Date,
                                      sessionEnd: Date) -> [NoopSleepInterval] {
        if let segments = segmentIntervals(stagesJSON) { return segments }
        guard sessionEnd > sessionStart else { return [] }
        return [NoopSleepInterval(start: sessionStart, end: sessionEnd, kind: .asleepUnspecified)]
    }

    /// Parse the COMPUTED segment-array `stagesJSON` into intervals, or nil when the string isn't that
    /// shape (so the caller can fall back to a whole-session span). Segment `start`/`end` are absolute
    /// unix seconds. Stage names mirror `SleepView.decodeSegments` exactly ("wake"/"awake" → awake,
    /// "light" → core, "deep" → deep, "rem" → rem); any other name, or a non-positive span, is skipped.
    static func segmentIntervals(_ json: String?) -> [NoopSleepInterval]? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var out: [NoopSleepInterval] = []
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue, end > start,
                  let name = seg["stage"] as? String else { continue }
            let kind: NoopSleepStageKind
            switch name {
            case "wake", "awake": kind = .awake
            case "light":         kind = .core
            case "deep":          kind = .deep
            case "rem":           kind = .rem
            default:              continue
            }
            out.append(NoopSleepInterval(
                start: Date(timeIntervalSince1970: TimeInterval(start)),
                end: Date(timeIntervalSince1970: TimeInterval(end)),
                kind: kind))
        }
        return out.isEmpty ? nil : out
    }
}
