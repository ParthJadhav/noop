import Foundation

// CaptureAccumulator.swift - the per-mode day/night capture accumulator (#965).
//
// #965 taught us the Test Centre "Capturing K of N" row was lying: K came from ceil(elapsedDays), a pure
// wall-clock proxy that advances (or sits) regardless of whether the mode actually captured anything. A
// tester running Sleep + Battery + Steps together saw every row stuck at "1 of 3" because the count was
// never tied to real captured data at all: it counted elapsed time, not distinct days each mode produced
// its own trace on. Worse, a shared clock meant the three modes could never diverge - one number drove
// them all - so a mode that captured three nights and a mode that captured none read identically.
//
// This is the honest replacement: for a given domain, count the DISTINCT local calendar days that
// domain's own tagged trace lines carry, so each active mode INDEPENDENTLY accumulates its own count off
// the shareable strap log. A domain that captured nights on three different days reads 3; a dead-trace
// mode reads 0. Sleep counts nights (its `sleep day=` / `[sleep] gate run=` lines), Battery counts days
// (its `[battery] bank soc= t=<unix>s` samples, folded to a local day), Steps counts days (`stepsRaw
// day=`), and the universal `dayOwner day=` line accumulates once per scored day for the universal row.
//
// Everything here is PURE and side-effect-free: it takes the domain, the already-redacted report text and
// a timezone offset and returns an Int. No I/O, no live clock, no PII (it only extracts day keys and unix
// stamps that are already in the log). The Kotlin twin is CaptureAccumulator.kt, kept aligned by a parity
// test (same day-token map, same fold). No em-dashes.

public enum CaptureAccumulator {

    /// Per-domain "how a captured day shows up in the log". `.dayKey` domains write an explicit
    /// `day=YYYY-MM-DD` on their trace line (the day the night/score is attributed to); `.epoch` domains
    /// write a `t=<unix>s` wall stamp (battery banks a SoC sample per reading, not a day-keyed row) that we
    /// fold to a LOCAL calendar day. A domain not listed here has no day-bearing trace, so its captured-day
    /// count is 0 (never a fabricated number). The token(s) also SCOPE the scan so an unrelated line that
    /// happens to carry `day=` is not counted toward the wrong mode.
    enum DayMarker: Equatable {
        case dayKey(tokens: [String])   // a `day=YYYY-MM-DD` on a line carrying any of `tokens`
        case epoch(tokens: [String])    // a `t=<unix>s` on a line carrying any of `tokens`
    }

    /// The declarative {domain -> day-marker} map. Tokens are the verbatim leading text the live emitters
    /// write (verified against the emitters, mirroring CaptureCompleteness.tokens), so a captured-day count
    /// is scoped to that mode's own lines. A domain absent from the map accumulates 0 (no day-bearing trace).
    ///
    ///   sleep       -> the per-day sleep-provenance line (`sleep day=YYYY-MM-DD ...`)
    ///   steps       -> the raw step-counter trace (`stepsRaw day=YYYY-MM-DD ...`)
    ///   recovery    -> the per-day Charge line (`charge ... day=YYYY-MM-DD` / `charge day=YYYY-MM-DD ...`)
    ///   battery     -> the banked SoC series (`bank soc=... t=<unix>s`), folded to a local day
    ///   universal   -> the dayOwner self-diagnostic (`dayOwner day=YYYY-MM-DD ...`), one per scored day
    static let markers: [TestDomain: DayMarker] = [
        .sleep:     .dayKey(tokens: ["sleep day=", "gate run="]),
        .steps:     .dayKey(tokens: ["stepsRaw", "stepsEst day="]),
        .recovery:  .dayKey(tokens: ["charge "]),
        .battery:   .epoch(tokens: ["bank soc="]),
        .universal: .dayKey(tokens: ["dayOwner "]),
    ]

    /// yyyy-MM-dd matcher for `day=<key>`. A separate scan for the unix stamp on epoch lines.
    private static let dayKeyRegex = try? NSRegularExpression(pattern: "day=([0-9]{4}-[0-9]{2}-[0-9]{2})")
    private static let epochRegex = try? NSRegularExpression(pattern: "\\bt=([0-9]{6,})s")

    /// The count of DISTINCT local calendar days `domain` captured, read from `reportText`. `.dayKey`
    /// domains contribute the set of `day=` keys on their tagged lines; `.epoch` domains fold each `t=<unix>s`
    /// sample to a local day (via `tzOffsetSeconds`, seconds EAST of UTC, the same convention
    /// `AnalyticsEngine.dayString(_:offsetSec:)` uses). A domain with no marker, or whose trace never landed,
    /// returns 0. Pure: no clock, no I/O.
    public static func capturedDays(domain: TestDomain, reportText: String, tzOffsetSeconds: Int) -> Int {
        capturedDayKeys(domain: domain, reportText: reportText, tzOffsetSeconds: tzOffsetSeconds).count
    }

    /// The SET of distinct local day keys `domain` captured (yyyy-MM-dd). Exposed for tests and for a caller
    /// that wants the keys, not just the count. Empty when the mode has no day-bearing trace / captured none.
    static func capturedDayKeys(domain: TestDomain, reportText: String, tzOffsetSeconds: Int) -> Set<String> {
        guard let marker = markers[domain] else { return [] }
        var days = Set<String>()
        for rawLine in reportText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            switch marker {
            case let .dayKey(tokens):
                guard tokens.contains(where: { line.contains($0) }) else { continue }
                if let key = firstDayKey(in: line) { days.insert(key) }
            case let .epoch(tokens):
                guard tokens.contains(where: { line.contains($0) }) else { continue }
                if let unix = firstEpoch(in: line) {
                    days.insert(AnalyticsEngine.dayString(unix, offsetSec: tzOffsetSeconds))
                }
            }
        }
        return days
    }

    /// Extract the first `day=YYYY-MM-DD` value on a line, or nil.
    private static func firstDayKey(in line: String) -> String? {
        guard let re = dayKeyRegex else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Extract the first `t=<unix>s` value on a line, or nil.
    private static func firstEpoch(in line: String) -> Int? {
        guard let re = epochRegex else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }
}
