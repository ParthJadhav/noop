package com.noop.testcentre

/**
 * Guided "wear it N days, then Report" capture for the Battery test mode (#713, Test Centre). Twin of the
 * Swift BatteryGuidedCapture. Arming reuses the daily scheduled export (the DebugExportScheduler settings)
 * so a redacted bundle drops each morning while the mode runs; the day count is derived from the
 * started-at timestamp against the registry default, so there is no extra persisted clock to drift. The
 * status formatter is pure (ms in) so it is JVM-unit-testable. No em-dashes.
 */
object BatteryGuidedCapture {

    private const val DAY_MS = 86_400_000L

    /** "Capturing day K of N" for the Test Centre Battery row. K = full-days-elapsed + 1, capped at N;
     *  once N whole days pass it reads complete. Pure (now injected) so it is unit-testable. */
    fun statusText(startedAtMs: Long?, target: Int, nowMs: Long): String {
        if (startedAtMs == null) return "Not started"
        val elapsedDays = ((nowMs - startedAtMs) / DAY_MS).toInt()
        if (elapsedDays >= target) return "Capture complete, $target of $target days"
        return "Capturing day ${elapsedDays + 1} of $target"
    }
}
