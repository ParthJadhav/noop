import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
import StrandDesign
@testable import Strand

/// Deep Timeline read facade (#575): the adaptive bucket-vs-raw decision that keeps the chart from ever
/// drawing ~86k points, and the live read path that preserves the #156 PPG COALESCE so a PPG-only WHOOP 5
/// day still renders. The pure decision is tested in isolation; the store path runs against an in-memory
/// WhoopStore via the DEBUG `setStoreForTesting` seam.
final class DeepTimelineFacadeTests: XCTestCase {

    // MARK: - Pure adaptive-resolution decision

    /// A whole DAY at the default budget picks a COARSE bucket — never raw (raw 86k seconds would be the
    /// drawn-points blow-up #575 guards against).
    func testDayScalePicksCoarseBuckets() {
        let bucket = Repository.timelineBucketSeconds(spanSeconds: 86_400, targetPoints: 600)
        XCTAssertGreaterThan(bucket, 1, "a full day must downsample, not read raw seconds")
        // ~86400/600 ≈ 144 → snaps up to the 300 s step; either way it's well above 1.
        XCTAssertGreaterThanOrEqual(bucket, 120)
    }

    /// A SMALL zoomed-in window (a couple of minutes) where the raw seconds already fit the budget reads
    /// RAW (bucket == 1) so the user inspects real beats.
    func testSmallWindowPicksRawSeconds() {
        // 120 s window, 600 target → ideal 0 → raw.
        XCTAssertEqual(Repository.timelineBucketSeconds(spanSeconds: 120, targetPoints: 600), 1)
        // 300 s window, 600 target → ideal 0 → raw.
        XCTAssertEqual(Repository.timelineBucketSeconds(spanSeconds: 300, targetPoints: 600), 1)
        // Right at the boundary: 600 s / 600 = 1 → still raw (ideal not > 1).
        XCTAssertEqual(Repository.timelineBucketSeconds(spanSeconds: 600, targetPoints: 600), 1)
    }

    /// The bucket snaps UP to a friendly step (so neighbouring zoom levels share boundaries and don't
    /// shimmer while panning), and is monotonic: a wider span never reads a finer bucket than a narrower one.
    func testBucketSnapsToFriendlyStepAndIsMonotonic() {
        // ideal ≈ 12 → snaps to 15.
        XCTAssertEqual(Repository.timelineBucketSeconds(spanSeconds: 7_200, targetPoints: 600), 15)
        let day = Repository.timelineBucketSeconds(spanSeconds: 86_400, targetPoints: 600)
        let twoHour = Repository.timelineBucketSeconds(spanSeconds: 7_200, targetPoints: 600)
        XCTAssertGreaterThanOrEqual(day, twoHour, "a wider window must not read finer than a narrower one")
    }

    /// The in-process bucketer (the non-HR twin of `hrBuckets`) means-bins onto the grid, ascending.
    func testDownsampleToBucketsMeanBinsOnGrid() {
        let base = 1_000
        let pts = [
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(base + 0)), value: 10),
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(base + 1)), value: 20),  // same 60s bucket as base
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(base + 61)), value: 30), // next 60s bucket
        ]
        let out = Repository.downsampleToBuckets(pts, bucketSeconds: 60)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].value, 15, accuracy: 0.001)   // mean of 10,20
        XCTAssertEqual(out[1].value, 30, accuracy: 0.001)
        XCTAssertLessThan(out[0].date, out[1].date)         // ascending
    }

    // MARK: - Off-main raw post-processing (the @MainActor-freeze fix)

    /// The zoomed-in HR raw post-processing is a pure, off-actor `nonisolated static` helper (it runs in a
    /// `Task.detached` so a dense day's ~200k 1 Hz rows don't beach-ball the UI). It dedups across the
    /// union FIRST-ID-WINS per ts (the active strap is first in `unionIds`) and returns ascending-sorted
    /// TrendPoints. Two id arrays with an OVERLAPPING ts must keep the first array's sample for that ts.
    func testRawHrDedupSortIsOffMainPure() {
        // id0 (active strap, first): ts 100 bpm 60, ts 102 bpm 62 (out of order to prove the sort).
        let id0 = [HRSample(ts: 102, bpm: 62), HRSample(ts: 100, bpm: 60)]
        // id1 (second source): ts 100 OVERLAPS id0 (must be dropped , first wins), ts 101 is new.
        let id1 = [HRSample(ts: 100, bpm: 99), HRSample(ts: 101, bpm: 61)]

        let out = Repository.dedupSortRawHr([id0, id1])

        // Three distinct ts (100, 101, 102) , the duplicate 100 collapsed to one point.
        XCTAssertEqual(out.map { Int($0.date.timeIntervalSince1970) }, [100, 101, 102], "ascending, deduped")
        // ts 100 kept id0's 60 bpm, NOT id1's 99 (first id wins per ts).
        XCTAssertEqual(out[0].value, 60, accuracy: 0.001)
        XCTAssertEqual(out[1].value, 61, accuracy: 0.001)
        XCTAssertEqual(out[2].value, 62, accuracy: 0.001)
    }

    /// The non-HR raw post-processing helper (also `nonisolated static`, also run in a `Task.detached`):
    /// dedups the union first-wins per ts, sorts ascending, and either returns the raw points (`isRaw`) or
    /// mean-bins onto the bucket grid. Same first-wins-on-overlap semantics as the in-line version it
    /// replaced.
    func testRawNonHrDedupSortIsOffMainPure() {
        func p(_ ts: Int, _ v: Double) -> TrendPoint {
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(ts)), value: v)
        }
        let id0 = [p(202, 22), p(200, 20)]              // first source, out of order
        let id1 = [p(200, 99), p(201, 21)]              // ts 200 overlaps id0 (dropped), 201 new

        let raw = Repository.dedupSortDownsampleRaw([id0, id1], isRaw: true, bucketSeconds: 1)
        XCTAssertEqual(raw.map { Int($0.date.timeIntervalSince1970) }, [200, 201, 202], "ascending, deduped")
        XCTAssertEqual(raw[0].value, 20, accuracy: 0.001, "first id wins the overlapping ts")
        XCTAssertEqual(raw[1].value, 21, accuracy: 0.001)
        XCTAssertEqual(raw[2].value, 22, accuracy: 0.001)
    }

    // MARK: - Live read facade (in-memory store)

    /// Day scale → coarse buckets (NOT raw). With a fully-worn hour of 1 Hz HR, a day-scale read returns a
    /// handful of bucket points, never the ~3600 raw rows for that hour.
    @MainActor
    func testDayScaleReturnsCoarseBuckets() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        let base = 1_780_000_000
        let hr = (0..<3_600).map { HRSample(ts: base + $0, bpm: 60 + ($0 % 20)) }
        try await store.insert(Streams(hr: hr), deviceId: dev)

        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)

        // A full-day window around the data.
        let series = await repo.timelineSeries(metric: .hr, from: base - 40_000, to: base + 46_400, targetPoints: 600)
        XCTAssertFalse(series.isRaw, "day scale must read buckets, not raw")
        XCTAssertGreaterThan(series.bucketSeconds, 1)
        // ~3600s of data / bucket ⇒ at most a couple dozen points, FAR below the raw 3600.
        XCTAssertLessThan(series.points.count, 200)
        XCTAssertGreaterThan(series.points.count, 0)
    }

    /// A small zoomed-in window returns RAW per-second rows — one point per measured second.
    @MainActor
    func testSmallWindowReturnsRawSeconds() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        let base = 1_780_000_000
        let hr = (0..<120).map { HRSample(ts: base + $0, bpm: 70) }
        try await store.insert(Streams(hr: hr), deviceId: dev)

        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)

        let series = await repo.timelineSeries(metric: .hr, from: base, to: base + 120, targetPoints: 600)
        XCTAssertTrue(series.isRaw, "a 2-minute window must read raw seconds")
        XCTAssertEqual(series.bucketSeconds, 1)
        // 121 inclusive seconds [base, base+120]; rows exist for base..<base+120.
        XCTAssertEqual(series.points.count, 120)
    }

    /// A PPG-ONLY day (no measured hrSample, only ppgHrSample) must NOT render empty — the #156 COALESCE
    /// surfaces the PPG-derived series on BOTH the zoomed-in raw path and the day-scale bucket path.
    @MainActor
    func testPpgOnlyDayReturnsPpgSeriesNotEmpty() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        let base = 1_780_000_000
        // No measured HR at all — only the v26 PPG-derived buffer (a WHOOP 5/MG PPG-only night).
        let ppg = (0..<300).map { PpgHrSample(ts: base + $0, bpm: 55, conf: 0.9) }
        try await store.insert(Streams(ppgHr: ppg), deviceId: dev)

        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)

        // Zoomed-in (raw) path: every PPG second surfaces (clears the night-stager gate, #172).
        let raw = await repo.timelineSeries(metric: .hr, from: base, to: base + 300, targetPoints: 600)
        XCTAssertTrue(raw.isRaw)
        XCTAssertEqual(raw.points.count, 300, "PPG-only raw read must not be empty")
        XCTAssertEqual(raw.points.first?.value, 55)

        // Day-scale (bucket) path: the PPG seconds average into buckets — still NOT empty.
        let day = await repo.timelineSeries(metric: .hr, from: base - 40_000, to: base + 46_400, targetPoints: 600)
        XCTAssertFalse(day.isRaw)
        XCTAssertGreaterThan(day.points.count, 0, "PPG-only day-scale read must not be empty")
        XCTAssertEqual(day.points.first?.value ?? 0, 55, accuracy: 0.001)
    }
}
