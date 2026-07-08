import Foundation
import StrandAnalytics

/// Builds the prefilled GitHub new-issue URL for a Test Centre report (spec section 5.2). It binds
/// the bug form's existing id fields (version, platform, os_version, test_profile, title) and
/// self-applies the "bug,test:<id>" labels so a submission lands pre-labelled on the right cluster.
/// No network, no cloud: this only composes a URL the caller opens in the browser. Repo is
/// NoopApp/noop (confirmed in bug_report.yml).
///
/// CAPTURE-A (#812): a report submitted WITHOUT the .zip attached used to land empty, because the form's
/// `log` / `what_happens` textareas were blank and the user often forgot the paperclip. We now PREFILL
/// those two id'd textareas from the already-redacted report.txt: the `log` field gets the last ~150
/// lines wrapped in a <details> block, and `what_happens` is seeded so the body is never empty even when
/// nothing is attached. The field ids `log` and `what_happens` match bug_report.yml exactly.
enum TestReportLink {

    /// How many trailing lines of the redacted report.txt to prefill into the `log` textarea. Kept SHORT
    /// (the recent killer-trace tokens: the universal `dayOwner` line, the clock-drift line, the
    /// per-domain emits) because the prefill rides INSIDE the URL: GitHub silently drops a new-issue
    /// prefill past ~8 KB (the user lands on an empty form), so a long tail defeats the whole point. The
    /// full trace travels in the attached/shared .zip, not the URL. A hard `maxURLLength` guard below
    /// drops the `log` param entirely if the URL would still be too long.
    static let logTailLines = 40

    /// Hard ceiling on the composed new-issue URL. GitHub starts dropping/emptying the prefill near 8 KB;
    /// we stay well under so the form always renders prefilled. If adding the `log` block would breach
    /// this, the URL is rebuilt WITHOUT `log` (the .zip still carries the full trace), never truncated
    /// mid-token into a broken <details> block.
    static let maxURLLength = 6000

    /// Percent-encodes a query value with a strict allowed set: alphanumerics plus the few chars we
    /// want to stay literal (colon, dot, hyphen, underscore). Crucially the comma in "bug,test:id" is
    /// NOT in the set so it encodes to %2C, byte-matching the Kotlin twin (URLComponents would leave
    /// the comma literal and diverge). Spaces and brackets in the title encode to %20 / %5B / %5D.
    private static func enc(_ v: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ":.-_")
        return v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
    }

    /// The last `logTailLines` lines of `reportText`, wrapped in a GitHub <details> block so the prefilled
    /// log collapses by default and doesn't dominate the issue. Returns nil when there is no usable text,
    /// so an empty report contributes no `log` param at all (rather than an empty <details>). PURE.
    static func logDetailsBlock(reportText: String, tailLines: Int = logTailLines) -> String? {
        // Split on newlines, drop a trailing empty line from a final "\n", take the last `tailLines`.
        var lines = reportText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        let tail = lines.suffix(tailLines).joined(separator: "\n")
        guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // A fenced code block inside <details> keeps the strap log monospaced and unparsed by Markdown.
        return "<details><summary>Strap log (last \(min(tailLines, lines.count)) lines, redacted)</summary>\n\n"
            + "```\n" + tail + "\n```\n</details>"
    }

    /// Seed text for the `what_happens` textarea from the mode's questionnaire answers (#812). Joins each
    /// answered prompt as "<prompt>: <answer>" so the body opens with the tester's own words instead of a
    /// blank box. Empty/blank answers are skipped; returns nil when nothing was answered (no `what_happens`
    /// param is then added, leaving the form's required field for the user to fill). PURE + deterministic
    /// (questions iterate in their declared order, not the dictionary's). The questionnaire prompts here
    /// carry no PII; the strap log (the only PII-shaped surface) is the already-redacted `log` block.
    static func whatHappensSeed(questionnaire: [Question], answers: [String: String]) -> String? {
        let parts: [String] = questionnaire.compactMap { q in
            guard let a = answers[q.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { return nil }
            return "\(q.prompt): \(a)"
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    /// The prefilled new-issue URL, or nil if it cannot form. `profile.id` is the wire id
    /// (dataImport -> "import"); `profile.githubLabel` is "test:<id>" (master -> "test:all").
    ///
    /// When `reportText` is supplied (the in-app Report flow passes the redacted report.txt), the form's
    /// `log` textarea is prefilled with its <details>-wrapped tail and `what_happens` is seeded with
    /// `whatHappensSeed` (the questionnaire-derived one-liner), so a submitted report carries the
    /// diagnostic trace even if the user never attaches the .zip (#812). Both default nil/empty so existing
    /// callers compose the same URL as before.
    static func reportURL(profile: TestDomain, title: String,
                          version: String, platform: String, osVersion: String,
                          reportText: String? = nil,
                          whatHappensSeed: String? = nil) -> URL? {
        var query = [
            "template=bug_report.yml",
            "labels=" + enc("bug,\(profile.githubLabel)"),
            "version=" + enc(version),
            "platform=" + enc(platform),
            "os_version=" + enc(osVersion),
            "test_profile=" + enc(profile.id),
            "title=" + enc("[\(profile.id)] \(title)"),
        ]
        // CAPTURE-A: seed what_happens so the body is never empty, and prefill the log tail (#812).
        if let seed = whatHappensSeed, !seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query.append("what_happens=" + enc(seed))
        }
        let base = "https://github.com/NoopApp/noop/issues/new?"
        // Add the log block ONLY if the whole URL stays under the GitHub prefill ceiling. If it would
        // breach maxURLLength, drop `log` entirely (never truncate it into a broken <details>); the full
        // trace is in the attached .zip. The seed + id fields alone keep the body non-empty (#812).
        if let reportText, let block = logDetailsBlock(reportText: reportText) {
            let withLog = query + ["log=" + enc(block)]
            if (base + withLog.joined(separator: "&")).count <= maxURLLength {
                query = withLog
            }
        }
        return URL(string: base + query.joined(separator: "&"))
    }
}
