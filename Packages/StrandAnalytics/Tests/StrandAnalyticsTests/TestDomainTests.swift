import XCTest
@testable import StrandAnalytics

final class TestDomainTests: XCTestCase {

    // dataImport is the one case whose wire id diverges from its rawValue: the spec reserves "import".
    func testDataImportWireIdIsImport() {
        XCTAssertEqual(TestDomain.dataImport.id, "import")
        XCTAssertEqual(TestDomain.dataImport.rawValue, "dataImport")
    }

    // Every other case's id equals its rawValue.
    func testNonImportIdsEqualRawValue() {
        for d in TestDomain.allCases where d != .dataImport {
            XCTAssertEqual(d.id, d.rawValue)
        }
    }

    // master maps to the catch-all label; a normal domain to "test:<id>".
    func testGithubLabels() {
        XCTAssertEqual(TestDomain.master.githubLabel, "test:all")
        XCTAssertEqual(TestDomain.sleep.githubLabel, "test:sleep")
        XCTAssertEqual(TestDomain.battery.githubLabel, "test:battery")
        XCTAssertEqual(TestDomain.dataImport.githubLabel, "test:import")
    }

    // The full id set is declared now so later phases just flip emitters on. Pin it.
    func testFullIdSet() {
        XCTAssertEqual(TestDomain.allCases.map(\.id), [
            "universal", "sleep", "connection", "workouts", "display", "import",
            "steps", "notifications", "battery", "recovery", "hrv", "sources",
            "stress", "longevity", "master",
        ])
    }
}
