package com.noop.testcentre

/**
 * The mandatory review-before-share gate (spec sections 9 and 12), twin of
 * Strand/System/ReportReviewGate.swift. Nothing is shared until the user has seen the exact redacted
 * report.txt and explicitly confirmed. Not skippable: confirm() is the only path to cleared. The
 * Compose review sheet binds to previewText and calls confirm() / cancel().
 */
class ReportReviewGate(private val entries: List<Pair<String, ByteArray>>) {

    var isCleared: Boolean = false
        private set

    /**
     * Every text file the user is about to share, so they can read the WHOLE bundle (not just report.txt)
     * and cancel if anything looks personal. Each text entry is prefixed with a `=== <name> ===` header so
     * report.txt, meta.json, and last-crash.txt (when present) are clearly delimited. The raw-capture
     * stream is excluded: it is the bounded binary capture (up to the 20 MB cap), not a report surface, and
     * is already PII-scrubbed by the assembler. "" if there is nothing text-decodable to show. Mirrors Swift.
     */
    val previewText: String
        get() {
            // Text files shown inline; the bounded raw-capture stream and any binary attachment (the
            // Display mode's screenshot.png) are excluded from the inline text. Mirrors Swift.
            val textBlocks = entries
                .filter { it.first != "raw-capture.jsonl" && !isBinaryEntry(it.first) }
                .joinToString("\n\n") { (name, data) -> "=== $name ===\n${String(data)}" }
            // Name the binary attachments so the review is HONEST about everything in the bundle: the user
            // sees that a screenshot is attached and can cancel if they don't want to share it.
            val binaryNames = entries.map { it.first }.filter { isBinaryEntry(it) }
            if (binaryNames.isEmpty()) return textBlocks
            val note = "=== attached (not shown above) ===\n" + binaryNames.joinToString("\n")
            return if (textBlocks.isEmpty()) note else textBlocks + "\n\n" + note
        }

    /** A bundle entry that is binary image bytes (not text to show inline). screenshot.png is the only one. */
    private fun isBinaryEntry(name: String): Boolean = name == DisplayScreenshot.BUNDLE_NAME

    /** Explicit user confirmation: the only way the gate clears. */
    fun confirm() { isCleared = true }
    /** Explicit cancel: leaves the gate uncleared so the share never fires. */
    fun cancel() { isCleared = false }
}
