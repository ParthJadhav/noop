import XCTest
@testable import StrandAnalytics

final class TestCentreLayoutTests: XCTestCase {

    // MARK: - Section 1 projection (priority order + requires5MG filter)

    /// The registered modes project in priority order (high before med); none requires 5/MG, so a
    /// WHOOP 4.0 owner sees all of them, the high-priority profiles first.
    func testPhase1OrderHighThenMed() {
        let rows = TestCentreLayout.visibleModes(is5MG: false)
        XCTAssertEqual(rows.map { $0.domain },
                       [.sleep, .connection, .workouts, .display, .dataImport, .steps, .battery, .recovery, .hrv])
    }

    /// A 5/MG owner sees the same modes (none is gated), same order.
    func testFiveMGOwnerSeesSame() {
        let rows = TestCentreLayout.visibleModes(is5MG: true)
        XCTAssertEqual(rows.map { $0.domain },
                       [.sleep, .connection, .workouts, .display, .dataImport, .steps, .battery, .recovery, .hrv])
    }

    /// The filter drops a requires5MG mode for a 4.0 owner. Synthesised input proves the rule
    /// independently of which modes ship in Phase 1.
    func testRequires5MGHiddenForNon5MG() {
        let gated = TestMode(
            domain: .sources, title: "Gated", blurb: "", icon: "x", priority: .high,
            captures: [], questionnaire: [], liveReadout: [],
            capture: .toggle, includesScreenshot: false, requires5MG: true)
        let open = TestModeRegistry.sleep
        XCTAssertEqual(TestCentreLayout.order([gated, open], is5MG: false).map { $0.domain }, [.sleep])
        XCTAssertEqual(TestCentreLayout.order([gated, open], is5MG: true).map { $0.domain }, [.sources, .sleep])
    }

    // MARK: - Per-mode status string

    /// Inactive mode reads "Off" regardless of capture kind.
    func testStatusOff() {
        XCTAssertEqual(TestCentreLayout.statusText(for: TestModeRegistry.sleep, active: false, elapsedSeconds: nil), "Off")
    }

    /// A plain toggle mode that is active reads "On".
    func testStatusToggleOn() {
        let m = TestMode(domain: .sleep, title: "", blurb: "", icon: "", priority: .high,
                         captures: [], questionnaire: [], liveReadout: [],
                         capture: .toggle, includesScreenshot: false, requires5MG: false)
        XCTAssertEqual(TestCentreLayout.statusText(for: m, active: true, elapsedSeconds: 3600), "On")
    }

    /// A guided 3-night mode, 25 hours in, is on night 2 of 3 (ceil of elapsed days, clamped to target).
    func testStatusGuidedMidCapture() {
        XCTAssertEqual(
            TestCentreLayout.statusText(for: TestModeRegistry.sleep, active: true, elapsedSeconds: 25 * 3600),
            "Capturing 2 of 3 nights")
    }

    /// Past the target window the count clamps to the target (does not over-run).
    func testStatusGuidedComplete() {
        XCTAssertEqual(
            TestCentreLayout.statusText(for: TestModeRegistry.battery, active: true, elapsedSeconds: 10 * 86400),
            "Capturing 3 of 3 days")
    }

    // MARK: - Honest per-mode captured count (#965)

    /// When a real captured count is supplied it DRIVES K, ignoring the elapsed proxy: two nights actually
    /// captured reads "2 of 3" even when the clock has barely elapsed (the #965 fix).
    func testStatusUsesCapturedUnitsOverElapsed() {
        XCTAssertEqual(
            TestCentreLayout.statusText(for: TestModeRegistry.sleep, active: true,
                                        elapsedSeconds: 5, capturedUnits: 2),
            "Capturing 2 of 3 nights")
    }

    /// A mode that captured NOTHING reads "0 of N" honestly (never the elapsed proxy's floor of 1). This is
    /// the honest replacement for the old "always shows 1" behaviour on a dead capture.
    func testStatusZeroCapturedReadsZero() {
        XCTAssertEqual(
            TestCentreLayout.statusText(for: TestModeRegistry.sleep, active: true,
                                        elapsedSeconds: 3 * 86400, capturedUnits: 0),
            "Capturing 0 of 3 nights")
    }

    /// A captured count past the target clamps to the target (never over-runs).
    func testStatusCapturedClampsToTarget() {
        XCTAssertEqual(
            TestCentreLayout.statusText(for: TestModeRegistry.battery, active: true,
                                        elapsedSeconds: 0, capturedUnits: 9),
            "Capturing 3 of 3 days")
    }

    /// Two guided modes with DIFFERENT captured counts read differently off the same call: they no longer
    /// share one elapsed number (the #965 "every row stuck at 1 of 3" regression).
    func testGuidedModesDivergeOnCapturedCount() {
        let sleep = TestCentreLayout.statusText(for: TestModeRegistry.sleep, active: true,
                                                elapsedSeconds: 0, capturedUnits: 3)
        let battery = TestCentreLayout.statusText(for: TestModeRegistry.battery, active: true,
                                                  elapsedSeconds: 0, capturedUnits: 1)
        XCTAssertEqual(sleep, "Capturing 3 of 3 nights")
        XCTAssertEqual(battery, "Capturing 1 of 3 days")
    }

    /// nil capturedUnits preserves the legacy elapsed proxy (backward compatible).
    func testStatusFallsBackToElapsedWhenNoCount() {
        XCTAssertEqual(
            TestCentreLayout.statusText(for: TestModeRegistry.sleep, active: true,
                                        elapsedSeconds: 25 * 3600, capturedUnits: nil),
            "Capturing 2 of 3 nights")
    }
}
