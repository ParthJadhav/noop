import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// #803: the Deep Timeline `.hrv` series used to plot RAW R-R milliseconds mislabelled "HRV". It now
/// plots a TRAILING-WINDOW rMSSD (HRVAnalyzer.rollingRmssd) that MOVES across the session, with the pill
/// honestly named "Windowed rMSSD". These tests pin the relabel, the pure window-width chooser, and the
/// store read facade producing rMSSD points (not raw rrMs).
final class HrvTimelineWindowedRmssdTests: XCTestCase {

    /// The pill / TimelineMetric.title for .hrv is honest: NOT the bare "HRV" and NOT "R-R".
    func testHrvMetricTitleIsHonest() {
        XCTAssertEqual(Repository.TimelineMetric.hrv.title, "Windowed rMSSD")
        XCTAssertNotEqual(Repository.TimelineMetric.hrv.title, "HRV", "must not relabel raw R-R as plain HRV (#803)")
    }

    /// The pure window-width chooser: a tight 2-minute floor when zoomed in, widening with the span, capped
    /// at 10 minutes. Pure + clamped so the series stays a readable line at every zoom.
    func testRollingWindowChooserClampsAndWidens() {
        // Zoomed in: clamps up to the 120 s floor.
        XCTAssertEqual(Repository.hrvRollingWindowSec(spanSeconds: 60), 120)
        XCTAssertEqual(Repository.hrvRollingWindowSec(spanSeconds: 1), 120)
        // Mid span: ~1/30 of the span.
        XCTAssertEqual(Repository.hrvRollingWindowSec(spanSeconds: 9_000), 300)   // 9000/30 = 300
        // Whole day: clamps to the 600 s cap.
        XCTAssertEqual(Repository.hrvRollingWindowSec(spanSeconds: 86_400), 600)
        // Monotonic non-decreasing in span.
        XCTAssertLessThanOrEqual(Repository.hrvRollingWindowSec(spanSeconds: 600),
                                 Repository.hrvRollingWindowSec(spanSeconds: 6_000))
    }

    /// The `.hrv` read facade returns WINDOWED rMSSD points, not raw R-R. A steady ~1 Hz R-R stream with
    /// small beat-to-beat variation yields a low, plausible rMSSD (tens of ms), NEVER the raw ~900 ms
    /// interval value the old code plotted.
    @MainActor
    func testHrvSeriesReturnsWindowedRmssdNotRawRr() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        let base = 1_780_000_000
        // ~900 ms intervals (≈67 bpm) with a tiny ±8 ms wobble: rMSSD lands well under 100 ms, raw rrMs ≈ 900.
        let rr = (0..<600).map { i in
            RRInterval(ts: base + i, rrMs: 900 + (i % 2 == 0 ? 8 : -8))
        }
        try await store.insert(Streams(rr: rr), deviceId: dev)

        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)

        // A several-minute window → coarse (non-raw) path, exercising the rollingRmssd branch.
        let series = await repo.timelineSeries(metric: .hrv, from: base, to: base + 600, targetPoints: 600)
        XCTAssertFalse(series.points.isEmpty, "a dense R-R window must emit windowed-rMSSD points")
        for p in series.points {
            // rMSSD of an ~8 ms alternating wobble is ~16 ms, emphatically NOT the ~900 ms raw interval.
            XCTAssertLessThan(p.value, 200, "the series must be windowed rMSSD (ms), not raw R-R intervals")
            XCTAssertGreaterThan(p.value, 0)
        }
    }

    /// A sparse / empty R-R window emits nothing rather than a fabricated spike (rollingRmssd's
    /// minimum-beats gate). Honest empty state, never a noisy point.
    @MainActor
    func testHrvSeriesEmptyOnSparseWindow() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        let base = 1_780_000_000
        // Just two beats, below any usable window.
        try await store.insert(Streams(rr: [RRInterval(ts: base, rrMs: 900),
                                            RRInterval(ts: base + 1, rrMs: 905)]), deviceId: dev)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)
        let series = await repo.timelineSeries(metric: .hrv, from: base, to: base + 600, targetPoints: 600)
        XCTAssertTrue(series.points.isEmpty, "a sparse R-R window must emit no point, not a fabricated spike")
    }
}
