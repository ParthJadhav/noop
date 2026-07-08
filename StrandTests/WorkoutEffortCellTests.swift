import XCTest
@testable import Strand

/// #796 - the per-session Effort surfaced on each workout row. It reuses the SAME stored 0-100 strain
/// and the SAME `UnitFormatter.effortDisplay` every other Effort read-out routes through, so the row,
/// the Effort ring and the detail card never disagree. These pin: a captured strain renders on the
/// selected scale to one decimal, and a session with no strain shows the honest "-" rather than a 0.
final class WorkoutEffortCellTests: XCTestCase {

    func testEffortLabelOnHundredScale() {
        // Stored 0-100 axis renders unchanged on the default Effort scale.
        XCTAssertEqual(WorkoutsView.effortCellLabel(strain: 60, scale: .hundred), "60.0")
    }

    func testEffortLabelOnWhoopScale() {
        // The WHOOP 0-21 scale applies the 21/100 factor (60 -> 12.6), matching every other read-out.
        XCTAssertEqual(WorkoutsView.effortCellLabel(strain: 60, scale: .whoop), "12.6")
    }

    func testMissingStrainShowsDash() {
        // The empty cell uses the en-dash glyph the other workout-row cells use (row.avgHr etc.).
        XCTAssertEqual(WorkoutsView.effortCellLabel(strain: nil, scale: .hundred), "\u{2013}")
        XCTAssertEqual(WorkoutsView.effortCellLabel(strain: nil, scale: .whoop), "\u{2013}")
    }

    func testZeroStrainRendersZeroNotDash() {
        // A real captured 0 is data, not "missing", so it must show as a number, not the empty dash.
        XCTAssertEqual(WorkoutsView.effortCellLabel(strain: 0, scale: .hundred), "0.0")
    }
}
