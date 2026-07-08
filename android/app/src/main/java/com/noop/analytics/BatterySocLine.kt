package com.noop.analytics

import java.util.Locale

/** Pure formatter for the Battery test mode's per-sample (t, soc) log line, kept out of the
 *  Android-bound BLE client so it is JVM-unit-testable. Matches the Swift "bank soc=.. t=..s" shape
 *  (#713, Test Centre). No em-dashes. */
object BatterySocLine {
    fun format(pct: Double, tSeconds: Long): String =
        "bank soc=${String.format(Locale.US, "%.1f", pct)} t=${tSeconds}s"
}
