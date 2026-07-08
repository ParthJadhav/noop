package com.noop.testcentre

import android.content.Context
import android.content.Intent
import android.net.Uri
import java.net.URLEncoder

/**
 * Builds the prefilled GitHub new-issue URL for a Test Centre report (spec section 5.2), the Kotlin
 * twin of Strand/System/TestReportLink.swift. Binds bug_report.yml's id fields and self-applies the
 * "bug,test:<id>" labels. reportUrlString is pure and unit-tested; reportUri wraps it for ACTION_VIEW.
 * Encoding matches the Swift URLComponents output (comma -> %2C, brackets -> %5B/%5D, space -> %20).
 *
 * CAPTURE-A (#812): a report submitted WITHOUT the .zip attached used to land empty, because the form's
 * `log` / `what_happens` textareas were blank and the user often forgot the paperclip. When the in-app
 * Report flow supplies the already-redacted report.txt, the `log` textarea is PREFILLED with its last
 * ~150 lines wrapped in a <details> block, so a submitted report carries the diagnostic trace (incl. the
 * universal `dayOwner` line) even if nothing is attached. Both new args default empty so existing callers
 * compose the same URL as before. The field ids `log` / `what_happens` match bug_report.yml.
 */
object TestReportLink {

    /** How many trailing lines of the redacted report.txt to prefill into the `log` textarea. Kept SHORT
     *  (the recent killer-trace tokens) because the prefill rides INSIDE the URL and GitHub silently drops
     *  a new-issue prefill past ~8 KB (empty form); the full trace travels in the attached/shared .zip.
     *  Mirrors the Swift logTailLines. */
    const val LOG_TAIL_LINES = 40

    /** Hard ceiling on the composed new-issue URL (GitHub empties the prefill near 8 KB; stay well under).
     *  If adding the `log` block would breach this, the URL is rebuilt WITHOUT `log` rather than truncated
     *  into a broken <details>. Mirrors the Swift maxURLLength. */
    const val MAX_URL_LENGTH = 6000

    /** Percent-encode a query value the same way URLComponents does for the characters we emit.
     *  URLEncoder maps space to "+", so we fix it to "%20"; URLEncoder also encodes ":" to "%3A", but
     *  URLComponents leaves a colon literal in a query value, so we restore it so "test:sleep" matches
     *  the Swift output byte-for-byte. */
    private fun enc(v: String): String =
        URLEncoder.encode(v, "UTF-8").replace("+", "%20").replace("%3A", ":")

    /**
     * CAPTURE-A: the last [tailLines] lines of [reportText], wrapped in a GitHub <details> block so the
     * prefilled log collapses by default and doesn't dominate the issue. Returns null when there is no
     * usable text, so an empty report contributes NO `log` param (rather than an empty <details>). Pure +
     * deterministic; byte-aligned with the Swift logDetailsBlock.
     */
    fun logDetailsBlock(reportText: String, tailLines: Int = LOG_TAIL_LINES): String? {
        val lines = reportText.split("\n").toMutableList()
        if (lines.isNotEmpty() && lines.last() == "") lines.removeAt(lines.size - 1)
        if (lines.isEmpty()) return null
        val tail = lines.takeLast(tailLines).joinToString("\n")
        if (tail.isBlank()) return null
        val shown = minOf(tailLines, lines.size)
        return "<details><summary>Strap log (last $shown lines, redacted)</summary>\n\n" +
            "```\n" + tail + "\n```\n</details>"
    }

    /**
     * CAPTURE-A: seed text for the `what_happens` textarea from the mode's questionnaire answers, so the
     * body opens with the tester's own words instead of a blank box. Joins each answered prompt as
     * "<prompt>: <answer>" in the questionnaire's declared order (deterministic). Blank answers are
     * skipped; returns null when nothing was answered (no `what_happens` param is added). The prompts
     * carry no PII; the strap log (the PII-shaped surface) is the already-redacted `log` block. Mirrors
     * the Swift whatHappensSeed.
     */
    fun whatHappensSeed(questionnaire: List<Question>, answers: Map<String, String>): String? {
        val parts = questionnaire.mapNotNull { q ->
            val a = answers[q.id]?.trim()
            if (a.isNullOrEmpty()) null else "${q.prompt}: $a"
        }
        return if (parts.isEmpty()) null else parts.joinToString("\n")
    }

    /** The pure URL string (no Android types) so it is testable on the plain JVM. When [reportText] is
     *  supplied the `log` textarea is prefilled with its <details>-wrapped tail, and a non-blank
     *  [whatHappensSeed] seeds the `what_happens` field (#812). */
    fun reportUrlString(profile: TestDomain, title: String,
                        version: String, platform: String, osVersion: String,
                        reportText: String? = null,
                        whatHappensSeed: String? = null): String {
        val items = ArrayList<Pair<String, String>>().apply {
            add("template" to "bug_report.yml")
            add("labels" to "bug,${profile.githubLabel}")
            add("version" to version)
            add("platform" to platform)
            add("os_version" to osVersion)
            add("test_profile" to profile.id)
            add("title" to "[${profile.id}] $title")
            // CAPTURE-A: seed what_happens so the body is never empty (#812).
            if (!whatHappensSeed.isNullOrBlank()) add("what_happens" to whatHappensSeed)
        }
        val base = "https://github.com/NoopApp/noop/issues/new?"
        fun render(list: List<Pair<String, String>>) = base + list.joinToString("&") { (k, v) -> "$k=${enc(v)}" }
        // Add the log block ONLY if the whole URL stays under the GitHub prefill ceiling; otherwise drop it
        // entirely (never truncate into a broken <details>) and rely on the attached/shared .zip (#812).
        if (reportText != null) {
            logDetailsBlock(reportText)?.let { block ->
                val withLog = items + ("log" to block)
                val rendered = render(withLog)
                if (rendered.length <= MAX_URL_LENGTH) return rendered
            }
        }
        return render(items)
    }

    /** The Uri for an ACTION_VIEW intent. Not unit-tested (Uri needs an Android runtime). */
    fun reportUri(profile: TestDomain, title: String,
                  version: String, platform: String, osVersion: String,
                  reportText: String? = null, whatHappensSeed: String? = null): Uri =
        Uri.parse(reportUrlString(profile, title, version, platform, osVersion, reportText, whatHappensSeed))

    /** Open the prefilled issue in the browser. Best-effort: a missing browser is swallowed. [reportText]
     *  (the already-redacted report.txt) prefills the `log` body so a no-attachment submission still
     *  carries the trace (CAPTURE-A / #812). */
    fun openReport(context: Context, profile: TestDomain, title: String,
                   version: String, platform: String, osVersion: String,
                   reportText: String? = null, whatHappensSeed: String? = null) {
        runCatching {
            val intent = Intent(Intent.ACTION_VIEW,
                reportUri(profile, title, version, platform, osVersion, reportText, whatHappensSeed))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }
    }
}
