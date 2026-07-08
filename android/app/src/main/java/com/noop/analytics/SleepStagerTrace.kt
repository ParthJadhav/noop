package com.noop.analytics

// SleepStagerTrace.kt - Kotlin twin of SleepStager+Trace.swift. Pure gate-trace line builders for
// the Sleep & Rest test mode. Byte-aligned with the Swift line shape so the parity test passes.
// No em-dashes. Counts and seconds only.

object SleepStagerTrace {
    enum class Verdict(val tag: String) { KEPT("KEPT"), DROPPED("DROPPED") }

    fun runLine(index: Int, startTs: Long, endTs: Long, verdict: Verdict, gate: String, detail: String): String {
        val spanS = maxOf(0L, endTs - startTs)
        return "gate run=$index spanS=$spanS ${verdict.tag} gate=$gate $detail"
    }

    fun flipLine(epoch: Int, from: String, to: String, threshold: String): String =
        "epoch=$epoch flip $from->$to threshold=$threshold"

    /** Round to 2 dp for the trace detail fields (AnalyticsEngine.round2 is private). Formatting only. */
    fun round2(v: Double): Double = Math.round(v * 100.0) / 100.0
}
