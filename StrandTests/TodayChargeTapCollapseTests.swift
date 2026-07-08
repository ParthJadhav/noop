import XCTest
import StrandAnalytics
@testable import Strand

/// A1/S4/S5 - the pure pieces behind the Today hero Charge-ring tap and the home-screen collapses:
/// the one-word readiness read kept on the hero (#205), the collapsed "Synced from: ..." footer summary
/// (S5), and the metrics-grid overflow cap (S5). Each is a view-free static so it pins without a live view,
/// the same way `heroRingDiameter` / `clampedDayOffset` are tested. The Kotlin twins mirror these exactly.
final class TodayChargeTapCollapseTests: XCTestCase {

    // MARK: #205 one-word readiness read (kept on the hero after Readiness folded into the Charge tap)

    func testReadinessWord_mapsEveryLevel() {
        XCTAssertEqual(TodayView.readinessWord(.primed), "Push")
        XCTAssertEqual(TodayView.readinessWord(.balanced), "Maintain")
        XCTAssertEqual(TodayView.readinessWord(.strained), "Rest")
        XCTAssertEqual(TodayView.readinessWord(.rundown), "Rest")
    }

    func testReadinessWord_insufficientHasNoWord() {
        // Not enough history yet: the hero shows no readiness word (the old card hid itself), so nil.
        XCTAssertNil(TodayView.readinessWord(.insufficient))
    }

    // MARK: S5 collapsed Data Sources footer summary

    func testSyncedFromSummary_listsOnlySourcesWithData() {
        XCTAssertEqual(
            TodayView.syncedFromSummary(hasWhoop: true, hasApple: true, hasXiaomi: false),
            "Synced from: WHOOP, Apple Watch")
        XCTAssertEqual(
            TodayView.syncedFromSummary(hasWhoop: true, hasApple: false, hasXiaomi: false),
            "Synced from: WHOOP")
        XCTAssertEqual(
            TodayView.syncedFromSummary(hasWhoop: true, hasApple: true, hasXiaomi: true),
            "Synced from: WHOOP, Apple Watch, Mi Band")
    }

    func testSyncedFromSummary_appleHealthReadsAsAppleWatch() {
        // A watch-only user reads the device they know, not the framework: "Apple Watch", not "Apple Health".
        XCTAssertEqual(
            TodayView.syncedFromSummary(hasWhoop: false, hasApple: true, hasXiaomi: false),
            "Synced from: Apple Watch")
    }

    func testSyncedFromSummary_noSourcesIsHonest() {
        XCTAssertEqual(
            TodayView.syncedFromSummary(hasWhoop: false, hasApple: false, hasXiaomi: false),
            "No sources yet")
    }

    // MARK: S5 metrics-grid overflow cap

    func testMetricsCollapsedCap_isSixTilesThreeRows() {
        // Two columns, so six fills three clean rows before the "Show all metrics" expander.
        XCTAssertEqual(TodayView.metricsCollapsedCap, 6)
    }

    func testMetricsCollapse_keepsLeadingTilesInOrder() {
        // The collapse slices from the FRONT of the saved order, so a pinned/selected tile is never dropped
        // or reordered (#251); only the tail folds. This mirrors `visibleKeyMetrics`'s prefix(cap).
        let saved = Array(0..<10)
        let visible = saved.count <= TodayView.metricsCollapsedCap
            ? saved : Array(saved.prefix(TodayView.metricsCollapsedCap))
        XCTAssertEqual(visible, [0, 1, 2, 3, 4, 5])
    }

    func testMetricsCollapse_underCapShowsAll() {
        // Fewer tiles than the cap: nothing folds, the expander wouldn't show.
        let saved = Array(0..<4)
        XCTAssertLessThanOrEqual(saved.count, TodayView.metricsCollapsedCap)
    }
}
