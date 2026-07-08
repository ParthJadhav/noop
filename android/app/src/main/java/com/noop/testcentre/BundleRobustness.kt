package com.noop.testcentre

/**
 * The bundle robustness check (Kotlin twin of the Swift BundleRobustness): a pure, last-line verifier
 * run over the ASSEMBLED, already-redacted, already-capped entries before they ship. It is the safety net
 * for the export pipeline: it confirms the bundle is well-formed (report.txt present and non-empty,
 * meta.json present), that the optional attachments are HONOURED when they should be (the Display mode's
 * screenshot.png, a captured crash's last-crash.txt), and crucially that redaction actually held - no raw
 * MAC address or WHOOP serial shape survived the scrub in ANY text entry (the #453 / 5.3 regression net).
 *
 * Why a separate check and not just trust the assembler: the assembler re-scrubs every file, but a future
 * edit could add an entry that bypasses redactEntries, or a redaction regex could regress. This check reads
 * the FINAL bytes the user is about to share and fails loud, so the review sheet / log surfaces "leak" or
 * "missing report.txt" rather than the bundle going out broken. Pure + side-effect-free (no IO, no clock);
 * tested directly on the JVM, and a parity test pins the leak patterns + summary shape against the Swift
 * twin. No PII in the output (it reports COUNTS and entry names only, never the offending text). No em-dashes.
 */
object BundleRobustness {

    /** Raw (un-redacted) PII shapes that must NEVER appear in a shipping text entry. These mirror the
     *  redaction regexes' INPUT shape, but match only the UNMASKED form: a full 6-octet MAC keeps all six
     *  octets (the redacted form has "••" in the middle four, so it won't match), and a WHOOP serial is the
     *  device-name serial (the redacted form is "WHOOP <serial>", which won't match the digit-led pattern).
     *  Byte-identical to the Swift twin's patterns. */
    private val RAW_MAC = Regex("[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}")
    private val RAW_WHOOP_SERIAL = Regex("WHOOP (\\d[0-9A-Za-z]{5,})")

    /** Entry names that are binary image bytes, excluded from the text/PII scan (a PNG would false-positive
     *  on the byte patterns). screenshot.png is the only one today. Mirrors the assembler's isBinaryEntry. */
    private fun isBinaryEntry(name: String): Boolean = name == DisplayScreenshot.BUNDLE_NAME

    /** A single robustness finding. [ok] is the overall verdict; the lists name what is missing / leaking
     *  (entry names only, never the offending text) so the summary is safe to log and to show in the gate. */
    data class Result(
        val ok: Boolean,
        val hasReport: Boolean,
        val reportNonEmpty: Boolean,
        val hasMeta: Boolean,
        val screenshotExpectedAndPresent: Boolean,
        val crashAttachedWhenCaptured: Boolean,
        val leakingEntries: List<String>,
    ) {
        /** One compact, PII-free line for the strap log / review surface, byte-identical to the Swift twin.
         *  "bundle ok files=N report=present meta=present screenshot=present crash=present leaks=0" or the
         *  matching failure form so a maintainer reads the verdict at a glance. */
        fun summaryLine(fileCount: Int): String =
            "bundle ${if (ok) "ok" else "FAIL"} files=$fileCount " +
                "report=${flag(hasReport && reportNonEmpty)} " +
                "meta=${flag(hasMeta)} " +
                "screenshot=${flag(screenshotExpectedAndPresent)} " +
                "crash=${flag(crashAttachedWhenCaptured)} " +
                "leaks=${leakingEntries.size}"

        private fun flag(b: Boolean): String = if (b) "present" else "MISSING"
    }

    /**
     * Verify the assembled [entries]. [expectScreenshot] is true when the active profile declares a
     * screenshot (Display, or any includesScreenshot mode) so a missing screenshot.png is a FAILURE rather
     * than expected absence. [crashWasCaptured] is true when CrashCapture had a crash to attach, so a
     * missing last-crash.txt is a failure; when no crash exists the attachment is correctly absent (we never
     * fabricate one). The redaction-leak scan runs over every TEXT entry's bytes.
     *
     * The verdict [ok] is true iff: report.txt is present and non-empty, meta.json is present, the screenshot
     * is present when expected, the crash is attached when one was captured, and NO text entry leaks a raw
     * MAC / serial. raw-capture.jsonl IS scanned (it is text JSON lines and is where embedded serials live);
     * the binary screenshot is excluded.
     */
    fun verify(
        entries: List<Pair<String, ByteArray>>,
        expectScreenshot: Boolean,
        crashWasCaptured: Boolean,
    ): Result {
        val report = entries.firstOrNull { it.first == "report.txt" }
        val hasReport = report != null
        val reportNonEmpty = (report?.second?.isNotEmpty() == true)
        val hasMeta = entries.any { it.first == "meta.json" }

        val hasScreenshot = entries.any { it.first == DisplayScreenshot.BUNDLE_NAME }
        // Present-when-expected: when a screenshot is expected it must be there; when it is NOT expected,
        // its absence is correct (so this flag is true). A screenshot present without being expected is not
        // a failure either (a mode could opt in), so we only fail the expected-but-absent case.
        val screenshotOk = if (expectScreenshot) hasScreenshot else true

        val hasCrash = entries.any { it.first == "last-crash.txt" }
        // Crash attached-when-captured: a captured crash must be in the bundle; no crash means correct absence.
        val crashOk = if (crashWasCaptured) hasCrash else true

        val leaking = entries
            .filterNot { isBinaryEntry(it.first) }
            .filter { (_, data) ->
                val text = String(data)
                RAW_MAC.containsMatchIn(text) || RAW_WHOOP_SERIAL.containsMatchIn(text)
            }
            .map { it.first }

        val ok = hasReport && reportNonEmpty && hasMeta && screenshotOk && crashOk && leaking.isEmpty()
        return Result(
            ok = ok,
            hasReport = hasReport,
            reportNonEmpty = reportNonEmpty,
            hasMeta = hasMeta,
            screenshotExpectedAndPresent = screenshotOk,
            crashAttachedWhenCaptured = crashOk,
            leakingEntries = leaking,
        )
    }
}
