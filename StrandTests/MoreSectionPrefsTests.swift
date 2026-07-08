import XCTest
@testable import Strand

/// Pins the More-tab section-expansion persistence (#860 item 2). The behaviour that must never regress:
/// the user's expanded/collapsed choice SURVIVES leaving + re-entering the More tab (and relaunch) instead
/// of resetting to the seed every visit. These exercise the pure encode/decode/default model that the
/// `@AppStorage`-backed `RootTabView` reads and writes through, and lock it in lockstep with the Android
/// `MoreSectionPrefs` twin (same key suffix, same CSV encoding, same Insights+Body default).
final class MoreSectionPrefsTests: XCTestCase {

    func testFreshInstallDefaultsToInsightsAndBody() {
        // The seed: Insights + Body open at rest, Data + App collapsed.
        XCTAssertEqual(MoreSectionPrefs.defaultExpanded, ["Insights", "Body"])
        XCTAssertEqual(MoreSectionPrefs.decode(MoreSectionPrefs.defaultCSV), ["Insights", "Body"])
    }

    func testKeyMatchesAndroidSuffix() {
        // iOS @AppStorage("more.expandedSections"); Android persists "noop.more.expandedSections".
        XCTAssertEqual(MoreSectionPrefs.storageKey, "more.expandedSections")
    }

    func testEncodeIsSortedAndDeterministic() {
        // Sorting makes the stored string deterministic regardless of insertion order, so the round-trip
        // and the default CSV are stable across runs.
        XCTAssertEqual(MoreSectionPrefs.encode(["Body", "App", "Insights"]), "App,Body,Insights")
        XCTAssertEqual(MoreSectionPrefs.encode(["Insights", "Body"]), "Body,Insights")
        XCTAssertEqual(MoreSectionPrefs.encode([]), "")
    }

    func testEncodeDecodeRoundTrips() {
        for set in [Set<String>(), ["Data"], ["Insights", "Body"], ["Insights", "Body", "Data", "App"]] {
            XCTAssertEqual(MoreSectionPrefs.decode(MoreSectionPrefs.encode(set)), set)
        }
    }

    func testEmptyStringDecodesToEmptySetNotTheSeed() {
        // A user who collapses EVERY group stores "" and must keep them all collapsed - the empty string is
        // a valid persisted state, not a fall-back to the Insights+Body seed.
        XCTAssertEqual(MoreSectionPrefs.decode(""), [])
        XCTAssertNotEqual(MoreSectionPrefs.decode(""), MoreSectionPrefs.defaultExpanded)
    }

    func testDecodeIgnoresBlankAndStrayTokens() {
        XCTAssertEqual(MoreSectionPrefs.decode("Insights, ,Body,"), ["Insights", "Body"])
        XCTAssertEqual(MoreSectionPrefs.decode("  Data  "), ["Data"])
    }

    func testCollapsedChoicePersistsThroughUserDefaults() {
        // The end-to-end persistence the screen relies on: writing the encoded set and reading it back
        // yields the same expanded set (here via a throwaway UserDefaults suite, as @AppStorage would).
        let suite = "MoreSectionPrefsTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // Nothing written: register the seed default, read it back.
        defaults.register(defaults: [MoreSectionPrefs.storageKey: MoreSectionPrefs.defaultCSV])
        XCTAssertEqual(MoreSectionPrefs.decode(defaults.string(forKey: MoreSectionPrefs.storageKey) ?? ""),
                       MoreSectionPrefs.defaultExpanded)

        // User expands Data too; it persists and reads back.
        defaults.set(MoreSectionPrefs.encode(["Insights", "Body", "Data"]), forKey: MoreSectionPrefs.storageKey)
        XCTAssertEqual(MoreSectionPrefs.decode(defaults.string(forKey: MoreSectionPrefs.storageKey) ?? ""),
                       ["Insights", "Body", "Data"])

        defaults.removePersistentDomain(forName: suite)
    }
}
