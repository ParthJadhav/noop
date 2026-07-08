import Foundation

// SleepStager+Trace.swift - the per-candidate-run GATE TRACE formatter (Sleep & Rest test mode).
//
// Pure, side-effect-free string builders. They never touch detection state, so a caller can
// assert the exact line a fixture night produces. Every emitter that USES these is gated by
// TestCentre.active(.sleep) at the detectSleep call site, and the lines exit through the
// redacting sink, so this file holds only formatting. Counts and seconds only, no wall-clock.

extension SleepStager {

    /// Whether a candidate in-bed run survived a gate or was dropped by it.
    public enum GateVerdict: String, Sendable { case kept = "KEPT", dropped = "DROPPED" }

    /// The gate-trace line formatters. Compact, parseable, no em-dashes.
    public enum GateTrace {

        /// One verdict line for a candidate run. `gate` names the constant that decided it
        /// (minSleepMin, maxMainSleepSpanS, offWrist, daytimeGuard, morningStillness, hrConfirm,
        /// sparseBridge, accepted); `detail` carries that gate's numbers. `startTs`/`endTs` give the
        /// span in seconds only (the sink scrubs identifiers; we never print a formatted clock here).
        public static func runLine(index: Int, startTs: Int, endTs: Int,
                                   verdict: GateVerdict, gate: String, detail: String) -> String {
            let spanS = max(0, endTs - startTs)
            return "gate run=\(index) spanS=\(spanS) \(verdict.rawValue) gate=\(gate) \(detail)"
        }

        /// One per-epoch wake<->sleep flip and the threshold it crossed.
        public static func flipLine(epoch: Int, from: String, to: String, threshold: String) -> String {
            "epoch=\(epoch) flip \(from)->\(to) threshold=\(threshold)"
        }
    }

    /// Round to 2 decimal places for the trace detail fields. Local to the trace so the inline
    /// emitters in `detectSleepUncached` can call it unqualified (AnalyticsEngine.round2 is a
    /// separate type's helper). Formatting only, never a scoring path.
    static func round2(_ v: Double) -> Double { (v * 100.0).rounded() / 100.0 }
}
