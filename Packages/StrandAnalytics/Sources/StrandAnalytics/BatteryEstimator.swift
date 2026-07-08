import Foundation

/// "~X days left" for a strap, worked out from its battery state-of-charge (SoC) history (#713). Neither
/// the WHOOP app nor WHOOP's API ever give you a runtime estimate, but NOOP already banks a SoC time
/// series from the strap over BLE, so no manual logging is needed. We fit the recent DISCHARGE slope and
/// divide the current charge by it. When the discharge run is too short or too flat to trust, we fall back
/// to the device's typical full-charge life for its generation.
///
/// The measured slope already bakes in how the user actually runs their strap (HR broadcast, strain,
/// recording), so there are no hand-tuned usage multipliers. The discharge curve IS the personalisation.
///
/// Honest about the limits: battery drain is non-linear (faster near full and near empty) and the strap
/// reports SoC sparsely, so this is an estimate, not a guarantee. Pure value type with no I/O. The Kotlin
/// twin is BatteryEstimator.kt, kept behaviour-identical (same fixtures, same numbers).
public enum BatteryEstimator {

    // MARK: - Rated full-charge life (the cold-start fallback)

    /// Typical full-charge life in hours per WHOOP generation, used before enough of the user's own
    /// discharge has been seen to fit a slope. WHOOP 4.0 is about 4.5 days, WHOOP 5.0 / MG about 12 days
    /// (the figures cited in #713). The caller maps its connected strap to one of these.
    public static let ratedLifeHoursWhoop4: Double = 108   // 4.5 days
    public static let ratedLifeHoursWhoop5: Double = 288   // 12 days

    /// A discharge run has to span at least this long AND drop at least this much before its measured
    /// slope is trusted over the rated fallback. Short or noisy spans produce wild rates.
    public static let minSpanHours: Double = 2.0
    public static let minDropPct: Double = 2.0

    /// A SoC rise larger than this (percentage points) between two consecutive readings marks a CHARGE.
    /// The discharge run restarts after it, so we never fit a rate across a charge.
    public static let chargeStepPct: Double = 1.0

    /// A charge only ANCHORS a fresh discharge run when it returns the strap NEAR FULL (#8). A mere partial
    /// top-up (e.g. 40% -> 55% on a quick desk charge) used to reset the run exactly like a 0% -> 100%
    /// charge, discarding the long clean discharge history before it and inflating "days left" off the short
    /// post-top-up tail. So a rise is treated as a run-reset anchor only when the post-rise SoC reaches this;
    /// a partial top-up is instead stepped over, and the fit prefers the longer pre-top-up discharge segment.
    public static let nearFullPct: Double = 90.0

    // MARK: - Output

    /// Where the drain rate came from: the user's own measured discharge, or the rated fallback.
    public enum Source: String, Equatable, Sendable { case measured, rated }

    public struct Estimate: Equatable, Sendable {
        /// Estimated hours of runtime left at the latest reading.
        public let remainingHours: Double
        public let source: Source
        /// The latest SoC the estimate is anchored to, in percent.
        public let currentSoc: Double

        public init(remainingHours: Double, source: Source, currentSoc: Double) {
            self.remainingHours = remainingHours
            self.source = source
            self.currentSoc = currentSoc
        }

        /// Convenience for callers that just want the days figure.
        public var daysRemaining: Double { remainingHours / 24 }
        /// Mirror so callers can read either name.
        public var hoursRemaining: Double { remainingHours }
    }

    // MARK: - Estimate

    /// Estimate remaining runtime from a SoC series.
    ///
    /// - Parameters:
    ///   - samples: `(unix-seconds, SoC%)` pairs in any order. The caller drops nil-SoC rows and maps the
    ///     banked battery series into this shape.
    ///   - ratedHours: the strap's typical full-charge life, one of the `ratedLifeHours…` constants,
    ///     chosen by the caller from the connected strap's generation.
    /// - Returns: an estimate, or nil when there isn't a single reading to anchor to.
    public static func estimate(samples: [(ts: Int, soc: Double)], ratedHours: Double) -> Estimate? {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard let last = sorted.last else { return nil }
        let current = last.soc

        // The discharge segment whose slope we fit: anchored at the most recent NEAR-FULL charge, and ending
        // before any later partial top-up, so neither a charge earlier in the buffer nor a quick desk top-up
        // distorts the fitted slope (#8).
        let run = dischargeFitWindow(sorted)

        // Fit the discharge slope over the segment as a simple endpoints rate (%/h). The series is short and
        // monotone-ish within a segment, so endpoints are as good as a least-squares line and far cheaper,
        // and they keep the test fixtures exact. nil when it's too short, too flat, or not discharging. The
        // estimate stays anchored to `current` (the latest SoC), even when the fit window ends earlier.
        let measuredRate: Double? = {
            guard run.count >= 2, let first = run.first, let lastRun = run.last else { return nil }
            let spanHours = Double(lastRun.ts - first.ts) / 3600.0
            let drop = first.soc - lastRun.soc
            guard spanHours >= minSpanHours, drop >= minDropPct else { return nil }
            let rate = drop / spanHours
            return rate > 0 ? rate : nil
        }()

        let rate = measuredRate ?? (100.0 / max(ratedHours, 1))
        let remaining = max(0, current) / rate
        // A fresh full charge can't realistically beat about 1.5x the rated life, so clamp out any wild
        // estimate from a near-flat measured run that still squeaked past the drop gate.
        let clamped = min(remaining, ratedHours * 1.5)
        return Estimate(remainingHours: clamped,
                        source: measuredRate != nil ? .measured : .rated,
                        currentSoc: current)
    }

    /// The slice of the sorted SoC series whose endpoints we fit the discharge slope on (#8). Two rules,
    /// both keyed off "is this rise a real charge or a partial top-up":
    ///   1. START at the most recent NEAR-FULL charge: the most recent rise > chargeStepPct that LANDS at
    ///      >= nearFullPct. A partial top-up (rise that doesn't reach near-full) is NOT an anchor: the scan
    ///      steps over it and keeps looking further back, so a quick 40->55 desk charge no longer throws away
    ///      the long clean discharge before it. If there is no near-full charge in the buffer, start = 0.
    ///   2. END before the most recent partial top-up that falls AFTER the start anchor, so the fitted slope
    ///      is the longer pre-top-up discharge segment, never the short, slope-flattening post-top-up tail.
    /// `current` (the latest SoC the estimate is anchored to) is taken by the caller from the series end, not
    /// from this window, so trimming the tail changes only the slope, never the SoC the runtime divides into.
    /// Pure; the Kotlin twin is `dischargeFitWindow`.
    static func dischargeFitWindow(_ sorted: [(ts: Int, soc: Double)]) -> [(ts: Int, soc: Double)] {
        guard sorted.count >= 2 else { return sorted }

        // 1. Most recent NEAR-FULL charge anchors the run start; partial top-ups are stepped over.
        var startIdx = 0
        for i in stride(from: sorted.count - 1, through: 1, by: -1)
        where sorted[i].soc > sorted[i - 1].soc + chargeStepPct && sorted[i].soc >= nearFullPct {
            startIdx = i
            break
        }

        // 1b. #919: with no near-full (>=90%) charge to anchor on - common on a 12-day WHOOP 5.0 that rarely
        //     tops past 90% between charges - anchor at the buffer's HIGHEST SoC (the top of the most recent
        //     discharge) rather than the oldest reading, which can sit below a later charge and net to a
        //     NON-discharge window (drop < 0 -> stuck on `rated`). The max is >= every later reading, so the
        //     window can only discharge; the >=minDropPct gate still rejects a flat run. Preserves #8: its
        //     buffer starts at the max, so this stays index 0 there. Last occurrence of the max (>=), for
        //     parity with the Kotlin twin.
        if startIdx == 0 {
            var maxIdx = 0
            for i in sorted.indices where sorted[i].soc >= sorted[maxIdx].soc { maxIdx = i }
            startIdx = maxIdx
        }

        // 2. End before the most recent PARTIAL top-up after the start anchor (a rise > chargeStepPct that
        //    does NOT reach near-full), so the fit prefers the longer pre-top-up discharge segment.
        var endIdx = sorted.count - 1
        if endIdx - startIdx >= 1 {
            for i in stride(from: sorted.count - 1, through: startIdx + 1, by: -1)
            where sorted[i].soc > sorted[i - 1].soc + chargeStepPct && sorted[i].soc < nearFullPct {
                endIdx = i - 1
                break
            }
        }
        guard endIdx > startIdx else { return Array(sorted[startIdx...]) }
        return Array(sorted[startIdx...endIdx])
    }

    /// Side-effect-free diagnostic twin of `estimate`: returns the SAME `Estimate` plus a list of trace
    /// lines describing the full (t, soc) series, the detected charge step(s), the trailing discharge run
    /// start/span/drop, the fitted slope, and which gate (minSpanHours / minDropPct) decided source =
    /// measured vs rated. The Battery test mode gates this behind TestCentre.active(.battery) and feeds the
    /// lines to append(log:domain:.battery); when the mode is off it is never called, so there is zero
    /// cost. Pure: no clock, no I/O, so fixtures stay exact. The Kotlin twin is BatteryEstimator.estimateTrace.
    public static func estimateTrace(samples: [(ts: Int, soc: Double)], ratedHours: Double)
        -> (estimate: Estimate?, trace: [String]) {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard let last = sorted.last, let first0 = sorted.first else {
            return (nil, ["battery series=0 readings, no reading to anchor to"])
        }
        var lines: [String] = []
        lines.append("battery series=\(sorted.count) readings span \(first0.ts)..\(last.ts)s")
        for s in sorted { lines.append("battery read t=\(s.ts)s soc=\(socText(s.soc))") }

        // The most recent NEAR-FULL charge anchors the run start (same scan as estimate, #8); a partial
        // top-up does NOT anchor and is reported separately below.
        var startIdx = 0
        if sorted.count >= 2 {
            for i in stride(from: sorted.count - 1, through: 1, by: -1)
            where sorted[i].soc > sorted[i - 1].soc + chargeStepPct && sorted[i].soc >= nearFullPct {
                startIdx = i
                let rise = sorted[i].soc - sorted[i - 1].soc
                lines.append("battery chargeStep at t=\(sorted[i].ts)s +\(socText(rise))pp "
                    + "(>chargeStepPct \(socText(chargeStepPct)))")
                break
            }
        }
        // The most recent PARTIAL top-up after the anchor (a rise that does NOT reach near-full): the fit
        // ends before it and prefers the longer pre-top-up discharge segment (#8).
        if sorted.count >= 2, startIdx < sorted.count - 1 {
            for i in stride(from: sorted.count - 1, through: startIdx + 1, by: -1)
            where sorted[i].soc > sorted[i - 1].soc + chargeStepPct && sorted[i].soc < nearFullPct {
                let rise = sorted[i].soc - sorted[i - 1].soc
                lines.append("battery partialTopUp at t=\(sorted[i].ts)s +\(socText(rise))pp "
                    + "(<nearFullPct \(socText(nearFullPct))) -> fit pre-top-up segment")
                break
            }
        }
        let run = dischargeFitWindow(sorted)

        var spanPass = false
        var dropPass = false
        if run.count >= 2, let runFirst = run.first, let runLast = run.last {
            let spanHours = Double(runLast.ts - runFirst.ts) / 3600.0
            let drop = runFirst.soc - runLast.soc
            lines.append("battery dischargeRun start=\(runFirst.ts)s "
                + "span=\(hoursText(spanHours))h drop=\(socText(drop))pp")
            spanPass = spanHours >= minSpanHours
            dropPass = drop >= minDropPct
            if spanPass && dropPass && drop / spanHours > 0 {
                lines.append("battery slope=\(slopeText(drop / spanHours))pct/h fitted from run endpoints")
            }
        } else {
            lines.append("battery dischargeRun too short to fit (run=\(run.count) readings)")
        }

        let measured = spanPass && dropPass && run.count >= 2
            && (run.first!.soc - run.last!.soc) / (Double(run.last!.ts - run.first!.ts) / 3600.0) > 0
        lines.append("battery gate minSpanHours \(hoursText(minSpanHours)) "
            + "\(spanPass ? "PASS" : "FAIL"), minDropPct \(socText(minDropPct)) "
            + "\(dropPass ? "PASS" : "FAIL") -> source=\(measured ? "measured" : "rated")")

        return (estimate(samples: samples, ratedHours: ratedHours), lines)
    }

    private static func socText(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func hoursText(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func slopeText(_ v: Double) -> String { String(format: "%.1f", v) }

    /// Display rule from #713: show hours under 48h ("~14h"), days above ("~4.5 days"). Unit text only,
    /// the caller adds the "left" / "remaining" copy. Locale-free so the tests stay stable; the UI
    /// localises the number when it renders.
    public static func label(hours: Double) -> String {
        if hours < 48 { return "~\(Int(hours.rounded()))h" }
        return "~\(String(format: "%.1f", hours / 24)) days"
    }
}
