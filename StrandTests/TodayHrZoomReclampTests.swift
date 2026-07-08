import XCTest
@testable import Strand

/// #829 - the Today HR chart's pinch/drag zoom window must stay VALID as the loaded axis changes across
/// reloads, without yanking the user out of a live zoom. `reclampHrZoom` is the one pure rule behind that:
/// a day STEP (the window's start moves) drops the zoom so the new day opens at full scale; a same-day END
/// extension (today's window growing toward `now`) KEEPS the zoom but re-clamps it into the grown bounds so
/// a refresh can never leave the window sitting outside the day. Locked here so the contract can't drift.
final class TodayHrZoomReclampTests: XCTestCase {

    private func d(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    func testNilZoomStaysNil() {
        // No zoom in -> no zoom out, whatever the axis does.
        XCTAssertNil(TodayView.reclampHrZoom(nil, oldAxis: d(0)...d(86_400), newAxis: d(0)...d(90_000)))
    }

    func testDayStepDropsZoom() {
        // The start moved (a step to a different day): the zoom is dropped so the new day opens full-scale.
        let zoom = d(3_600)...d(7_200)
        let oldAxis = d(0)...d(86_400)
        let newAxis = d(86_400)...d(172_800)   // next day
        XCTAssertNil(TodayView.reclampHrZoom(zoom, oldAxis: oldAxis, newAxis: newAxis))
    }

    func testSameDayEndExtensionKeepsZoomWhenStillInBounds() {
        // Today's window grew (end moved from +50000s to +60000s); a zoom wholly inside both is unchanged.
        let zoom = d(10_000)...d(20_000)
        let oldAxis = d(0)...d(50_000)
        let newAxis = d(0)...d(60_000)
        let out = TodayView.reclampHrZoom(zoom, oldAxis: oldAxis, newAxis: newAxis)
        XCTAssertEqual(out?.lowerBound, zoom.lowerBound)
        XCTAssertEqual(out?.upperBound, zoom.upperBound)
    }

    func testSameDayKeepsSpanWhenReclamped() {
        // Even if the kept window needed clamping, its SPAN is preserved (it slides, never shrinks).
        let zoom = d(40_000)...d(50_000)       // 10_000s span near the old end
        let oldAxis = d(0)...d(50_000)
        let newAxis = d(0)...d(60_000)         // grown end
        let out = TodayView.reclampHrZoom(zoom, oldAxis: oldAxis, newAxis: newAxis)
        XCTAssertNotNil(out)
        let span = (out?.upperBound.timeIntervalSince1970 ?? 0) - (out?.lowerBound.timeIntervalSince1970 ?? 0)
        XCTAssertEqual(span, 10_000, accuracy: 1)
        // And it stays inside the new bounds.
        XCTAssertGreaterThanOrEqual(out!.lowerBound, newAxis.lowerBound)
        XCTAssertLessThanOrEqual(out!.upperBound, newAxis.upperBound)
    }

    func testFirstLoadReclampsIntoBounds() {
        // oldAxis nil (first load): the zoom is kept and clamped into the new bounds, not dropped.
        let zoom = d(10_000)...d(20_000)
        let newAxis = d(0)...d(60_000)
        let out = TodayView.reclampHrZoom(zoom, oldAxis: nil, newAxis: newAxis)
        XCTAssertEqual(out?.lowerBound, zoom.lowerBound)
        XCTAssertEqual(out?.upperBound, zoom.upperBound)
    }
}
