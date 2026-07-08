import Foundation

/// The mandatory review-before-share gate (spec sections 9 and 12): nothing leaves the device until the
/// user has seen the exact redacted report.txt they are about to share and explicitly confirmed. The
/// gate is a small value type so its clear/cancel logic is unit-tested; the SwiftUI review sheet binds
/// to `previewText` and calls `confirm()` / `cancel()`. It is NOT skippable: the only path to cleared
/// is an explicit confirm.
struct ReportReviewGate {
    /// The bundle the user is about to share, already redacted by TestBundleAssembler.
    let entries: [FileExport.BundleEntry]
    private(set) var isCleared: Bool = false

    init(entries: [FileExport.BundleEntry]) { self.entries = entries }

    /// Every text file the user is about to share, shown in the review sheet so they can read the WHOLE
    /// bundle (not just report.txt) and cancel if anything looks personal , the gate promises the user sees
    /// exactly what they share. Each text entry is prefixed with a `=== <name> ===` header so the three
    /// files (report.txt, meta.json, and last-crash.txt when present) are clearly delimited. The
    /// raw-capture stream is excluded: it is the bounded binary capture (up to the 20 MB cap), not a report
    /// surface, and is already PII-scrubbed by the assembler. Order is the natural bundle order. Empty
    /// string if there is nothing text-decodable to show.
    var previewText: String {
        let textBlocks = entries.compactMap { entry -> String? in
            guard entry.name != "raw-capture.jsonl",
                  let text = String(data: entry.data, encoding: .utf8) else { return nil }
            return "=== \(entry.name) ===\n\(text)"
        }.joined(separator: "\n\n")
        // Binary attachments (the Display mode's screenshot.png, raw-capture.jsonl) are not text, so they
        // cannot be shown inline. Name them so the review is honest about EVERYTHING in the bundle: the
        // user sees that a screenshot is attached and can cancel if they don't want to share it.
        let binaryNames = entries.compactMap { entry -> String? in
            if entry.name == "raw-capture.jsonl" || entry.name == "screenshot.png" { return entry.name }
            return String(data: entry.data, encoding: .utf8) == nil ? entry.name : nil
        }
        guard !binaryNames.isEmpty else { return textBlocks }
        let note = "=== attached (not shown above) ===\n" + binaryNames.joined(separator: "\n")
        return textBlocks.isEmpty ? note : textBlocks + "\n\n" + note
    }

    /// Explicit user confirmation: the only way the gate clears.
    mutating func confirm() { isCleared = true }
    /// Explicit cancel: leaves the gate uncleared so the share never fires.
    mutating func cancel() { isCleared = false }
}
