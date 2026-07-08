package com.noop.testcentre

/**
 * The report-completeness guard (Kotlin twin of the Swift ReportCompleteness). A report is only useful
 * if the active mode's KILLER TRACE actually landed in report.txt. The Test Centre's whole point is that
 * each domain emits one upfront, hard-to-miss line that settles the bug; if a tester toggles a mode but
 * the emitter never fires (strap never connected, no scored day, the import never ran), the .zip looks
 * full but carries nothing diagnostic. This guard reads report.txt back and reports, per active domain,
 * whether its killer-trace token is present, so a maintainer (and the tester, via the review sheet) sees
 * "Sleep: MISSING" before the report ships rather than after a round-trip.
 *
 * The {domain -> token} map below is the SINGLE source of truth and is byte-identical to the Swift twin
 * (same domains, same token substrings). Each token is the distinctive, stable leading fragment of that
 * domain's killer trace (verified against the trace emitters and their unit tests): a SUBSTRING match is
 * deliberate so the per-day / per-record suffix (counts, ids, ISO dates) can vary without breaking the
 * check. The UNIVERSAL token (`dayOwner day=`) rides every export, so it is checked on every report.
 *
 * Pure + side-effect-free (no clock, no IO): the assembler passes the assembled report.txt text and the
 * active-domain set, and gets back the lines to append. No PII (tokens are fixed format fragments). No
 * em-dashes. Tested directly on the JVM, and a parity test pins the map against the Swift twin.
 */
object ReportCompleteness {

    /** The status label written into the Capture check section + meta.json per checked domain. PRESENT
     *  when the killer trace landed, MISSING when the mode is on but its emitter never fired. */
    enum class Status(val token: String) { PRESENT("present"), MISSING("MISSING") }

    /**
     * domain -> the distinctive leading substring of that domain's killer trace. Byte-identical to the
     * Swift twin's map. UNIVERSAL's `dayOwner day=` rides every export (checked always); the rest are
     * checked only when their mode is active. NOTIFICATIONS / SOURCES / STRESS / LONGEVITY have no wired
     * emitter yet (Phase 3), so they are intentionally absent from the map and never claimed present.
     */
    val killerTokens: Map<TestDomain, String> = linkedMapOf(
        TestDomain.UNIVERSAL to "dayOwner day=",
        TestDomain.SLEEP to "gate run=",
        TestDomain.CONNECTION to "clockDrift ",
        TestDomain.WORKOUTS to "session event=",
        TestDomain.DISPLAY to "dataVolume dbRows=",
        TestDomain.IMPORT to "import parser=",
        TestDomain.STEPS to "stepsEst ",
        TestDomain.BATTERY to "battery series=",
        TestDomain.RECOVERY to "charge score=",
        TestDomain.HRV to "hrv rmssd=",
    )

    /**
     * The ordered set of domains to check for a report: the UNIVERSAL line (always), plus each active
     * domain that has a known killer token, in [killerTokens] declaration order so the Capture check
     * section reads identically on both platforms regardless of which modes are on. A domain active but
     * absent from the map (a Phase-3 mode with no emitter) is skipped, never reported MISSING for a trace
     * we never promised to emit.
     */
    fun checkedDomains(active: Set<TestDomain>): List<TestDomain> =
        killerTokens.keys.filter { it == TestDomain.UNIVERSAL || it in active }

    /** Per-domain presence map for [reportText], over [checkedDomains]. A token is PRESENT iff its
     *  substring occurs anywhere in the report text. Deterministic order (killerTokens order). */
    fun statuses(reportText: String, active: Set<TestDomain>): LinkedHashMap<TestDomain, Status> {
        val out = LinkedHashMap<TestDomain, Status>()
        for (d in checkedDomains(active)) {
            val token = killerTokens[d] ?: continue
            out[d] = if (reportText.contains(token)) Status.PRESENT else Status.MISSING
        }
        return out
    }

    /**
     * The "Capture check" section appended to report.txt (byte-identical to the Swift twin): a header,
     * then one `<domainId>: <present|MISSING> (<token>)` line per checked domain in deterministic order,
     * then a footer flag when any active domain's trace is MISSING (the at-a-glance "this report carries
     * no diagnostic for X" signal). Returns the section WITHOUT a leading newline; the assembler joins it.
     */
    fun captureCheckSection(reportText: String, active: Set<TestDomain>): String {
        val statuses = statuses(reportText, active)
        val sb = StringBuilder()
        sb.append("=== Capture check ===")
        for ((d, status) in statuses) {
            sb.append('\n')
                .append(d.id).append(": ").append(status.token)
                .append(" (").append(killerTokens[d]).append(')')
        }
        // Only an ACTIVE domain going MISSING is a problem; the universal line is informational. If any
        // active, mapped domain is MISSING, flag it so the maintainer reads it without scanning the list.
        val missingActive = statuses.entries
            .filter { it.key != TestDomain.UNIVERSAL && it.value == Status.MISSING }
            .map { it.key.id }
        sb.append('\n')
        if (missingActive.isEmpty()) {
            sb.append("complete: all active traces present")
        } else {
            sb.append("INCOMPLETE: missing ").append(missingActive.joinToString(", "))
        }
        return sb.toString()
    }

    /** The meta.json `capture_check` value: a {domainId -> "present"|"MISSING"} map plus the `complete`
     *  flag, for the machine-readable tie. Keys are the wire ids; emitted in sorted order by TestBundleMeta
     *  so the JSON bytes line up with the Swift twin. */
    fun captureCheckMeta(reportText: String, active: Set<TestDomain>): CaptureCheckMeta {
        val statuses = statuses(reportText, active)
        val map = LinkedHashMap<String, String>()
        for ((d, status) in statuses) map[d.id] = status.token
        val complete = statuses.entries.none { it.key != TestDomain.UNIVERSAL && it.value == Status.MISSING }
        return CaptureCheckMeta(traces = map, complete = complete)
    }

    /** The meta.json capture_check block: per-domain trace presence + the overall complete flag. */
    data class CaptureCheckMeta(val traces: Map<String, String>, val complete: Boolean)
}
