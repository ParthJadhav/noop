import XCTest
@testable import Strand

/// Pins the Settings "Advanced" disclosure defaults (S3). The fact that must never regress is the
/// DEFAULT: a fresh install lands COLLAPSED, so a first-run user sees the everyday handful of sections
/// instead of the full wall of cards. Also guards the @AppStorage key stays in lockstep with the Android
/// `SettingsDisclosurePrefs.KEY` suffix so a backup/restore round-trip carries the choice across platforms.
final class SettingsDisclosureDefaultsTests: XCTestCase {

    func testFreshInstallDefaultsCollapsed() {
        XCTAssertFalse(SettingsDisclosureDefaults.advancedOpenDefault,
                       "The Advanced disclosure must default collapsed so first-run isn't a wall of cards.")
    }

    func testKeyMatchesAndroidSuffix() {
        // iOS @AppStorage("settingsAdvancedOpen"); Android persists "noop.settingsAdvancedOpen".
        XCTAssertEqual(SettingsDisclosureDefaults.advancedOpenKey, "settingsAdvancedOpen")
    }

    func testDefaultRoundTripsThroughUserDefaults() {
        // Registering the default value reads back as collapsed when nothing has been written.
        let defaults = UserDefaults(suiteName: "SettingsDisclosureDefaultsTests")!
        defaults.removePersistentDomain(forName: "SettingsDisclosureDefaultsTests")
        defaults.register(defaults: [SettingsDisclosureDefaults.advancedOpenKey: SettingsDisclosureDefaults.advancedOpenDefault])
        XCTAssertFalse(defaults.bool(forKey: SettingsDisclosureDefaults.advancedOpenKey))

        // A user opening it persists true and reads back true.
        defaults.set(true, forKey: SettingsDisclosureDefaults.advancedOpenKey)
        XCTAssertTrue(defaults.bool(forKey: SettingsDisclosureDefaults.advancedOpenKey))
        defaults.removePersistentDomain(forName: "SettingsDisclosureDefaultsTests")
    }
}
