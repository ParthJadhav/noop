import Foundation

// MARK: - More-tab section expansion persistence (#860 item 2)
//
// The iPhone "More" tab's collapsible groups (Insights / Body / Data / App) must REMEMBER whether each
// group is expanded or collapsed - leaving and re-entering the tab (or relaunching) should not reset the
// user's choice back to the seed every time. The expanded state is persisted as the set of EXPANDED group
// titles, encoded as one sorted comma-joined string under a single `@AppStorage` key in `RootTabView`.
//
// This type holds ONLY the pure, platform-agnostic key + encode/decode/default - no UIKit, no SwiftUI - so
// it compiles into both the macOS and iOS targets and is unit-tested in `StrandTests` (the same split
// `BackupSync` uses). It mirrors the Android `MoreSectionPrefs` one-for-one: same `more.expandedSections`
// key suffix, same CSV-of-titles encoding, same Insights+Body default, so the two platforms behave the same.

/// Pure persistence model for the More tab's collapsible-group state. The stored value is the set of
/// EXPANDED group titles as a sorted, comma-joined string; an empty string is a valid state (every group
/// collapsed), distinct from "never set" (which yields the Insights+Body seed via `@AppStorage`'s default).
enum MoreSectionPrefs {
    /// The `@AppStorage` / UserDefaults key. The Android twin namespaces this as `noop.more.expandedSections`.
    static let storageKey = "more.expandedSections"

    /// Groups open by default at first run; Data + App collapse to just their header so the list reads
    /// shorter at rest without dropping a single row. Mirrors the Android `defaultExpanded` flags.
    static let defaultExpanded: Set<String> = ["Insights", "Body"]

    /// The default expressed as the stored CSV (sorted, so the seed string is deterministic and testable).
    static var defaultCSV: String { encode(defaultExpanded) }

    /// Encode a set of expanded titles to a sorted, comma-joined string (sorted for a stable round-trip).
    static func encode(_ titles: Set<String>) -> String {
        titles.sorted().joined(separator: ",")
    }

    /// Decode the stored CSV back to a set of expanded titles. Blank tokens are dropped; an EMPTY string
    /// decodes to the empty set (every group collapsed) - a deliberate, valid state, NOT the seed, so a
    /// user who collapses every group keeps them collapsed across visits.
    static func decode(_ csv: String) -> Set<String> {
        Set(csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}
