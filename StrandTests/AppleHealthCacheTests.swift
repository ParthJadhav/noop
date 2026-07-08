import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// #833/v7.7.2 (Apple Health per-source freeze): the load-once contract behind the AppleHealthView re-mount
/// cache. On macOS the NavigationSplitView detail is keyed with `.id`, so every sidebar switch cold-mounts the
/// screen and tears down its `@State`; without the repo-level cache each visit re-ran the whole apple-health
/// history read on the @MainActor, which is the freeze. The fix parks the snapshot on the long-lived
/// `Repository` (`performAppleHealthLoad`), so a same-state re-mount RESTORES it in-memory instead of
/// re-querying.
///
/// These tests drive the shared seam directly (the view just copies its result into `@State`, which can't be
/// exercised headlessly) and pin two things:
///   1. Load-once: TWO `allowCache: true` loads at an UNCHANGED `refreshSeq` fire the heavy store read exactly
///      ONCE (the second short-circuits from cache). This is the regression guard for the freeze.
///   2. Invalidation: nulling the cache (what the import / delete handlers do, since body-composition series
///      live in metricSeries OUTSIDE refresh()'s diff) forces the next load to re-read.
@MainActor
final class AppleHealthCacheTests: XCTestCase {

    private let appleSource = "apple-health"

    /// Seed a handful of apple-health body-composition + vitals series days into an in-memory store and hand it
    /// to a fresh Repository. Body-comp keys (weight/body_fat/lean_mass/bmi/vo2max) are the ones that live ONLY
    /// in metricSeries, so they exercise the exact staleness path the invalidation fix guards.
    private func makeRepo() async throws -> Repository {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")

        var rows: [MetricPoint] = []
        let days = ["2026-06-24", "2026-06-25", "2026-06-26", "2026-06-27", "2026-06-28"]
        for (i, day) in days.enumerated() {
            rows.append(MetricPoint(day: day, key: "weight", value: 74.0 + Double(i) * 0.1))
            rows.append(MetricPoint(day: day, key: "body_fat", value: 18.0 - Double(i) * 0.1))
            rows.append(MetricPoint(day: day, key: "steps", value: 8_000 + Double(i) * 100))
            rows.append(MetricPoint(day: day, key: "hrv", value: 60 + Double(i)))
        }
        _ = try await store.upsertMetricSeries(rows, deviceId: appleSource)

        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        return repo
    }

    /// The keys AppleHealthView pulls, so the seam reads the same set the screen does.
    private let seriesKeys = [
        "steps", "active_kcal", "vo2max",
        "resting_hr", "hrv", "spo2", "resp_rate", "asleep_min",
        "weight", "body_fat", "lean_mass", "bmi"
    ]

    /// The core regression guard: two same-state re-mount loads run the heavy store read ONCE. The second call
    /// (unchanged `refreshSeq`, same dayKey, cache present) must short-circuit and NOT bump the fire tally.
    func testSecondLoadAtUnchangedSeqShortCircuitsFromCache() async throws {
        let repo = try await makeRepo()

        // First cold-mount: genuine heavy load, populates the cache and returns real data.
        let first = await repo.performAppleHealthLoad(seriesKeys: seriesKeys, allowCache: true)
        XCTAssertEqual(repo.loadFireCounts["appleHealth"], 1, "the first load must run the heavy read")
        XCTAssertEqual(first.series["weight"]?.count, 5, "the body-composition series loaded")
        XCTAssertEqual(first.series["weight"]?.last?.value ?? 0, 74.4, accuracy: 0.001)

        // Second same-state re-mount: MUST restore from cache, NOT re-read the store.
        let second = await repo.performAppleHealthLoad(seriesKeys: seriesKeys, allowCache: true)
        XCTAssertEqual(repo.loadFireCounts["appleHealth"], 1,
                       "the same-state re-mount must short-circuit from cache (the freeze regression guard)")
        // Restored snapshot is identical to the first load's result.
        XCTAssertEqual(second.series["weight"]?.map(\.value), first.series["weight"]?.map(\.value))
        XCTAssertEqual(second.appleRows.count, first.appleRows.count)
    }

    /// `allowCache: false` (the live-sync path, Enable / Sync now) always re-reads even at an unchanged seq, so
    /// a fresh sync's data is never masked by the cache.
    func testDirectLoadAlwaysReReadsRegardlessOfCache() async throws {
        let repo = try await makeRepo()
        _ = await repo.performAppleHealthLoad(seriesKeys: seriesKeys, allowCache: true)
        XCTAssertEqual(repo.loadFireCounts["appleHealth"], 1)

        // A non-cache load re-fires even though the seq is unchanged and a cache exists.
        _ = await repo.performAppleHealthLoad(seriesKeys: seriesKeys, allowCache: false)
        XCTAssertEqual(repo.loadFireCounts["appleHealth"], 2,
                       "a direct (non-cached) load must always re-read so a live sync is never masked")
    }

    /// Invalidation contract: dropping the cache (exactly what the Apple Health import / delete handlers do,
    /// because body-composition series live outside refresh()'s diff and refresh() may not bump `refreshSeq`)
    /// forces the next `allowCache: true` load to re-read the store, so post-import / post-delete data is fresh.
    func testNulledCacheForcesReReadEvenAtUnchangedSeq() async throws {
        let repo = try await makeRepo()
        _ = await repo.performAppleHealthLoad(seriesKeys: seriesKeys, allowCache: true)
        _ = await repo.performAppleHealthLoad(seriesKeys: seriesKeys, allowCache: true)
        XCTAssertEqual(repo.loadFireCounts["appleHealth"], 1, "cached, so still one heavy read")

        // Mimic the import / delete handlers' invalidation (they set exactly these two).
        repo.appleHealthCache = nil
        repo.appleHealthLoadedSeq = -1

        // Same `refreshSeq`, but the cache is gone → the next load MUST re-read.
        _ = await repo.performAppleHealthLoad(seriesKeys: seriesKeys, allowCache: true)
        XCTAssertEqual(repo.loadFireCounts["appleHealth"], 2,
                       "after invalidation the next load must re-read, so post-import/delete data is fresh")
    }
}
