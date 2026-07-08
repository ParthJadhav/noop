import XCTest
import StrandAnalytics
@testable import Strand

@MainActor
final class TestCentreActivationTests: XCTestCase {

    // A clean suite so the test never touches the real app defaults.
    private func freshDefaults() -> UserDefaults {
        let name = "TestCentreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    override func setUp() {
        super.setUp()
        // Reset the namespace this test relies on (TestCentre reads UserDefaults.standard).
        for d in TestDomain.allCases {
            UserDefaults.standard.removeObject(forKey: "testcentre.active.\(d.id)")
            UserDefaults.standard.removeObject(forKey: "testcentre.startedAt.\(d.id)")
            UserDefaults.standard.removeObject(forKey: "testcentre.answers.\(d.id)")
        }
        UserDefaults.standard.removeObject(forKey: "testcentre.migrated.v1")
    }

    func testActivateThenActiveThenDeactivate() {
        XCTAssertFalse(TestCentre.active(.sleep))
        TestCentre.activate(.sleep)
        XCTAssertTrue(TestCentre.active(.sleep))
        XCTAssertFalse(TestCentre.active(.battery))
        TestCentre.deactivate(.sleep)
        XCTAssertFalse(TestCentre.active(.sleep))
    }

    func testMasterImpliesAll() {
        TestCentre.activate(.master)
        XCTAssertTrue(TestCentre.active(.sleep))
        XCTAssertTrue(TestCentre.active(.battery))
        XCTAssertTrue(TestCentre.active(.hrv))
    }

    func testUniversalRidesAnyActiveMode() {
        XCTAssertFalse(TestCentre.active(.universal))   // nothing on
        TestCentre.activate(.battery)
        XCTAssertTrue(TestCentre.active(.universal))    // universal rides whatever is on
    }

    func testStartedAtStampedOnActivate() {
        XCTAssertNil(TestCentre.startedAt(.sleep))
        let before = Date()
        TestCentre.activate(.sleep)
        let s = TestCentre.startedAt(.sleep)
        XCTAssertNotNil(s)
        XCTAssertGreaterThanOrEqual(s!.timeIntervalSince1970, before.timeIntervalSince1970 - 1)
    }

    func testAnswersRoundTrip() {
        XCTAssertEqual(TestCentre.answers(.battery), [:])
        TestCentre.setAnswers(["whoopAppInstalled": "yes", "batterySaverApps": "none"], for: .battery)
        XCTAssertEqual(TestCentre.answers(.battery), ["whoopAppInstalled": "yes", "batterySaverApps": "none"])
    }

    // Migration seeds nothing destructive and is idempotent (guarded by the v1 bool).
    func testMigrationIsIdempotentAndPreservesLegacyKeys() {
        UserDefaults.standard.set(true, forKey: PuffinExperiment.deepDataKey)   // a legacy key set "before"
        TestCentre.migrate()
        TestCentre.migrate()                                                    // second call is a no-op
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "testcentre.migrated.v1"))
        XCTAssertTrue(UserDefaults.standard.bool(forKey: PuffinExperiment.deepDataKey))  // NOT renamed/wiped
    }
}
