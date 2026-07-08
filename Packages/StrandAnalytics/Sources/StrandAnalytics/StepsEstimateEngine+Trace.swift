import Foundation
import WhoopProtocol

// StepsEstimateEngine+Trace.swift - the Steps test-mode diagnostic traces.
//
// Two pure, side-effect-free twins for the two ways NOOP produces a step number:
//
//  1. calibrationTrace(...) - the WHOOP-4 motion-volume path. Reports each calibration day's motion VOLUME
//     and phone reference count, then the fitted (or manual) calibration state (k / sampleDays / confidence
//     / manual) by reusing StepsEstimateEngine.calibrate VERBATIM, so the trace can never disagree with the
//     coefficient the Settings/Steps screen shows. When the fit is withheld it names the status (the
//     "Need N more days" reason), the same status the tile renders.
//
//  2. rawCounterTrace(...) - the WHOOP 5/MG raw path. Reports the cumulative step_motion_counter series and
//     its WRAP-AWARE deltas (cur - prev) & 0xFFFF, the dropped deltas (>= 512, a sync-gap / reboot boundary,
//     not real steps), and the same total AnalyticsEngine.analyzeDay sums, with the SAME maxStepDelta gate
//     and the SAME ticks-per-step scaling, so the trace and the daily steps_est value can never diverge.
//
// No clock, no I/O, no PII (counts and ratios only). A fixture pins the exact lines. The Steps test mode
// gates each call behind TestCentre.active(.steps) at the call site (IntelligenceEngine); when the mode is
// off neither is ever called, so there is zero cost. No em-dashes. The Kotlin twin is StepsEstimateEngineTrace.

extension StepsEstimateEngine {

    /// The WHOOP-4 motion-volume calibration trace. Given the per-day calibration points (each a motion
    /// volume + a phone reference step count) and the optional manual override, it logs:
    ///   - one `stepsCal point` line per usable day (the day's motion volume and phone reference count, plus
    ///     the implied steps/motion ratio that votes in the fit),
    ///   - the calibration outcome line, built by reusing `calibrate(...)` VERBATIM (so k / sampleDays /
    ///     confidence / manual are exactly what the Settings screen reads), or the `status(...)` line naming
    ///     why the fit was withheld (e.g. needsMoreDays have/need).
    ///
    /// Every number is the SAME expression the production fit uses, and the reported coefficient IS
    /// `calibrate(...)`'s, so the trace can never diverge from the headline. The Kotlin twin is
    /// `StepsEstimateEngineTrace.calibrationTrace`.
    public static func calibrationTrace(points: [CalibrationPoint],
                                        manualOverride: Double? = nil) -> [String] {
        func r2(_ x: Double) -> Double { (x * 100.0).rounded() / 100.0 }

        var lines: [String] = []

        // Per-usable-day points: the SAME filter the fit applies (motion >= minMotionForFit && steps > 0),
        // so the trace shows exactly the days that voted. Phone reference count is the calibration anchor.
        let usable = points.filter { $0.motion >= minMotionForFit && $0.steps > 0 }
        for p in usable {
            let ratio = p.motion > 0 ? p.steps / p.motion : 0
            lines.append("stepsCal point motion=\(r2(p.motion)) phoneRef=\(Int(p.steps)) "
                + "ratio=\(r2(ratio)) (steps/motion votes weighted by motion)")
        }

        // The calibration outcome, read from calibrate(...) verbatim so it matches the stored coefficient.
        if let cal = calibrate(points, manualOverride: manualOverride), usable.count >= minCalibrationDays || cal.manual {
            lines.append("stepsCal fit k=\(r2(cal.coefficient)) sampleDays=\(cal.sampleDays) "
                + "confidence=\(r2(cal.confidence)) manual=\(cal.manual) "
                + "(k = motion-weighted median of steps/motion)")
        } else {
            // Withheld: name the status the tile shows (the "need N more days" reason), via status(...)
            // verbatim so the trace explains the blank tile with the SAME usable-day filter.
            let status = self.status(points, manualOverride: manualOverride)
            switch status {
            case let .needsMoreDays(have, need):
                lines.append("stepsCal withheld reason=needsMoreDays have=\(have) need=\(need) "
                    + "(no usable auto-fit and no manual k)")
            case let .manual(k, sampleDays):
                lines.append("stepsCal fit k=\(r2(k)) sampleDays=\(sampleDays) "
                    + "confidence=1.0 manual=true (user-set k)")
            case let .calibrated(k, sampleDays, confidence):
                lines.append("stepsCal fit k=\(r2(k)) sampleDays=\(sampleDays) "
                    + "confidence=\(r2(confidence)) manual=false (k = motion-weighted median of steps/motion)")
            }
        }
        return lines
    }

    /// The WHOOP 5/MG raw-counter trace for one day. Recomputes the SAME wrap-aware sum
    /// `AnalyticsEngine.analyzeDay` runs over the cumulative `step_motion_counter` series: the time-ordered
    /// records filtered to the LOCAL day, each consecutive `(cur - prev) & 0xFFFF` increment, the dropped
    /// deltas (>= `maxStepDelta`, a sync-gap / reboot boundary), and the `ticksPerStep` scaling. Reports the
    /// counter series length, the kept/dropped delta counts, the raw tick total and the scaled steps - the
    /// SAME value the daily `steps_est` carries (byte-identical math), so the trace can never diverge.
    ///
    /// - Parameters mirror the analyzeDay step block exactly: the day's step samples (any order), the local
    ///   day key, the tz offset, and the user's ticks-per-step. `daySteps` is the calendar-day stream the
    ///   production total prefers. The Kotlin twin is `StepsEstimateEngineTrace.rawCounterTrace`.
    public static func rawCounterTrace(daySteps: [StepSample],
                                       dayKey: String,
                                       tzOffsetSeconds: Int,
                                       ticksPerStep: Double) -> [String] {
        // The SAME maxStepDelta gate AnalyticsEngine.analyzeDay uses for the daily steps total.
        let maxStepDelta = 512

        // The SAME filter + sort: keep only this LOCAL day's samples, time-ordered.
        let sorted = daySteps
            .filter { AnalyticsEngine.dayString($0.ts, offsetSec: tzOffsetSeconds) == dayKey }
            .sorted { $0.ts < $1.ts }

        var lines: [String] = []
        // #810: a WHOOP 4.0 sends NO raw step counter over BLE at all, so `sorted` is empty for it; its
        // steps are MOTION-ESTIMATED (the calibrationTrace path), not counted. Emitting the bare
        // "counterSamples=0 (need >=2 for a delta)" line made a 4.0 export read as BROKEN. When there is
        // no counter sample at all, say so honestly so the trace reflects the model, not a fault. (A 5/MG
        // with a single counter sample still falls through to the "need >=2" line: it HAS a counter, just
        // one read this window.) The Kotlin twin emits the same branch first; keep them byte-identical.
        if sorted.isEmpty {
            lines.append("stepsRaw day=\(dayKey) counterSamples=0 noRawCounter "
                + "(no step counter on this device; steps are motion-estimated, e.g. WHOOP 4.0)")
            return lines
        }
        guard sorted.count >= 2 else {
            lines.append("stepsRaw day=\(dayKey) counterSamples=\(sorted.count) (need >=2 for a delta)")
            return lines
        }

        // Walk the wrap-aware deltas exactly as the production sum does.
        var rawTotal = 0
        var keptDeltas = 0
        var droppedDeltas = 0
        var minDelta = Int.max
        var maxDelta = Int.min
        for i in 1..<sorted.count {
            let delta = (sorted[i].counter - sorted[i - 1].counter) & 0xFFFF  // wrap-aware u16 increment
            if delta >= 1 && delta < maxStepDelta {
                rawTotal += delta
                keptDeltas += 1
                minDelta = Swift.min(minDelta, delta)
                maxDelta = Swift.max(maxDelta, delta)
            } else if delta >= maxStepDelta {
                droppedDeltas += 1   // a sync-gap / reboot boundary, not real steps (>= 512)
            }
        }

        let firstCounter = sorted.first!.counter
        let lastCounter = sorted.last!.counter
        lines.append("stepsRaw day=\(dayKey) counterSamples=\(sorted.count) "
            + "firstCounter=\(firstCounter) lastCounter=\(lastCounter) (cumulative u16 @57)")
        lines.append("stepsRaw deltas kept=\(keptDeltas) dropped=\(droppedDeltas) "
            + "(dropped = delta>=\(maxStepDelta), a sync-gap/reboot boundary)")
        if keptDeltas > 0 {
            lines.append("stepsRaw keptRange min=\(minDelta) max=\(maxDelta) "
                + "(each = (cur-prev)&0xFFFF, wrap-aware)")
        }

        // The scaled total, the SAME expression analyzeDay produces for steps_est (ticks / ticksPerStep,
        // floored at 0.5 so a bad pref can at most double, never explode, the total).
        let scaled = rawTotal > 0
            ? Int((Double(rawTotal) / Swift.max(ticksPerStep, 0.5)).rounded())
            : 0
        // L7: production analyzeDay returns `scaled > 0 ? scaled : nil`, so a tiny rawTotal that rounds to 0
        // yields NO steps_est for the day. Render "none" (not 0) so the trace matches the nil headline rather
        // than implying a real zero-step measurement.
        let scaledText = scaled > 0 ? String(scaled) : "none"
        lines.append("stepsRaw total rawTicks=\(rawTotal) ticksPerStep=\((ticksPerStep * 100).rounded() / 100) "
            + "scaledSteps=\(scaledText) (steps_est for the day)")
        return lines
    }
}
