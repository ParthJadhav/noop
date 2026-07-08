import XCTest
@testable import Strand

/// #762 - the hero ring diameter sizing behind the Today rings. The bug was a LAYOUT one: the three-ring
/// row was wrapped in a GeometryReader pinned to a fixed 150pt height, so once a Charge/Rest ring also
/// rendered its provenance badge (the two-line SourceBadge + ScoreStatePill block) the column overflowed
/// 150pt and the badge clipped/overlapped the content below. The fix lets the row self-size in height and
/// sizes the rings off the row's MEASURED width via `heroRingDiameter(rowWidth:)`. The clamp behind that
/// width-to-diameter map is the pure, view-free piece worth pinning: it must stay inside [82, 98] so the
/// trio never crushes on a narrow phone nor bloats on a wide iPad, while scaling smoothly between.
final class TodayHeroRingLayoutTests: XCTestCase {

    func testNarrowPhoneWidth_clampsToMinimumDiameter() {
        // A cramped width must floor at 82 so two-plus rings never crush together.
        XCTAssertEqual(TodayView.heroRingDiameter(rowWidth: 240), 82, accuracy: 0.01)
        XCTAssertEqual(TodayView.heroRingDiameter(rowWidth: 100), 82, accuracy: 0.01)
    }

    func testWideTabletWidth_clampsToMaximumDiameter() {
        // A wide iPad/landscape width must cap at 98 so the rings don't bloat the hero.
        XCTAssertEqual(TodayView.heroRingDiameter(rowWidth: 900), 98, accuracy: 0.01)
        XCTAssertEqual(TodayView.heroRingDiameter(rowWidth: 1200), 98, accuracy: 0.01)
    }

    func testTypicalPhoneWidth_scalesWithinBounds() {
        // A standard ~345pt phone content width lands inside the clamp, scaling smoothly (not pinned to an
        // edge) so the rings track the device width.
        let d = TodayView.heroRingDiameter(rowWidth: 345)
        XCTAssertGreaterThanOrEqual(d, 82)
        XCTAssertLessThanOrEqual(d, 98)
        XCTAssertEqual(d, (345 - 56) / 3.4, accuracy: 0.01)
    }

    func testDiameterIsMonotonicInWidth() {
        // Wider rows never yield a smaller ring - the map is non-decreasing across the range.
        let widths: [CGFloat] = [120, 240, 300, 345, 400, 600, 900]
        for (a, b) in zip(widths, widths.dropFirst()) {
            XCTAssertLessThanOrEqual(TodayView.heroRingDiameter(rowWidth: a),
                                     TodayView.heroRingDiameter(rowWidth: b),
                                     "diameter must not shrink as the row gets wider (\(a) -> \(b))")
        }
    }
}
