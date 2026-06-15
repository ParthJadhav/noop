import XCTest
import GRDB
@testable import WhoopStore

final class MetricsCacheTests: XCTestCase {

    func testV4CreatesDerivedTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("sleepSession"))
        XCTAssertTrue(tables.contains("dailyMetric"))
        let sleepPK = try await store.primaryKeyColumns("sleepSession")
        XCTAssertEqual(sleepPK, ["deviceId", "startTs"])
        let dailyPK = try await store.primaryKeyColumns("dailyMetric")
        XCTAssertEqual(dailyPK, ["deviceId", "day"])
    }

    func testSchemaVersionBumped() {
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 15)
    }

    // MARK: - sleep sessions

    func testSleepSessionUpsertReadAndIdempotency() async throws {
        let store = try await WhoopStore.inMemory()
        let s = CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: 0.92,
                                   restingHr: 52, avgHrv: 65.5,
                                   stagesJSON: "[{\"start\":1000,\"end\":2000,\"stage\":\"deep\"}]")
        try await store.upsertSleepSessions([s], deviceId: "devA")

        var rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], s)

        // Re-upsert the same natural key with updated values → no duplicate, value updated.
        let s2 = CachedSleepSession(startTs: 1000, endTs: 6000, efficiency: 0.95,
                                    restingHr: 50, avgHrv: 70.0, stagesJSON: nil)
        try await store.upsertSleepSessions([s2], deviceId: "devA")
        rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1, "same (deviceId,startTs) must not duplicate")
        XCTAssertEqual(rows[0].endTs, 6000)
        XCTAssertEqual(rows[0].efficiency, 0.95)
        XCTAssertNil(rows[0].stagesJSON)
    }

    func testSleepSessionRangeFilter() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 100, endTs: 200, efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
            CachedSleepSession(startTs: 500, endTs: 600, efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ], deviceId: "devA")
        let rows = try await store.sleepSessions(deviceId: "devA", from: 400, to: 1000, limit: 100)
        XCTAssertEqual(rows.map { $0.startTs }, [500])
    }

    // MARK: - v13 user-edited sleep bounds (#367 parity: edits survive re-sync)

    func testV13UserEditedColumnPresent() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("userEdited"), "sleepSession missing v13 userEdited column")
    }

    func testUserEditedDefaultsFalseAndRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        // A recompute/import session never sets the flag → defaults false.
        try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: 0.9,
                                restingHr: 52, avgHrv: 60, stagesJSON: nil)],
            deviceId: "devA")
        let rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].userEdited)
    }

    func testSetSleepWakeTimeUpdatesEndTsAndMarksEdited() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: 0.9,
                                restingHr: 52, avgHrv: 60, stagesJSON: nil)],
            deviceId: "devA")

        let changed = try await store.applySleepEdit(deviceId: "devA", detectedStartTs: 1000, newStartTs: 1000, newEndTs: 4200)
        XCTAssertEqual(changed, 1)

        let rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1, "editing must not create a duplicate row")
        XCTAssertEqual(rows[0].endTs, 4200, "corrected wake time persisted")
        XCTAssertTrue(rows[0].userEdited, "session is now flagged user-edited")
    }

    func testSetSleepWakeTimeNoopWhenSessionMissing() async throws {
        let store = try await WhoopStore.inMemory()
        let changed = try await store.applySleepEdit(deviceId: "devA", detectedStartTs: 9999, newStartTs: 9999, newEndTs: 4200)
        XCTAssertEqual(changed, 0, "no matching session → no rows changed")
    }

    func testSetSleepWakeTimeReplacesStagesWhenProvidedAndKeepsThemWhenNil() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: 0.9,
                                restingHr: 52, avgHrv: 60, stagesJSON: "[\"old\"]")],
            deviceId: "devA")

        // Non-nil stagesJSON reshapes the stored breakdown to the edited window.
        try await store.applySleepEdit(deviceId: "devA", detectedStartTs: 1000, newStartTs: 1000,
                                       newEndTs: 4200, stagesJSON: "[\"reclipped\"]")
        var rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows[0].endTs, 4200)
        XCTAssertEqual(rows[0].stagesJSON, "[\"reclipped\"]")
        XCTAssertTrue(rows[0].userEdited)

        // A nil stagesJSON (nothing reclippable) keeps whatever stages are already stored.
        try await store.applySleepEdit(deviceId: "devA", detectedStartTs: 1000, newStartTs: 1000, newEndTs: 4000, stagesJSON: nil)
        rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows[0].endTs, 4000)
        XCTAssertEqual(rows[0].stagesJSON, "[\"reclipped\"]", "nil stagesJSON preserves existing stages")
    }

    func testApplySleepEditStoresAdjustedOnsetAndSurvivesRecompute() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: 0.9,
                                restingHr: 52, avgHrv: 60, stagesJSON: "[\"orig\"]")],
            deviceId: "devA")
        // Correct BOTH onset (1000 → 1300) and wake (5000 → 4200). The detected key stays 1000.
        try await store.applySleepEdit(deviceId: "devA", detectedStartTs: 1000, newStartTs: 1300,
                                       newEndTs: 4200, stagesJSON: "[\"restaged\"]")
        var rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].startTs, 1000, "detected onset key is unchanged")
        XCTAssertEqual(rows[0].startTsAdjusted, 1300, "corrected onset stored")
        XCTAssertEqual(rows[0].effectiveStartTs, 1300)
        XCTAssertEqual(rows[0].endTs, 4200)
        XCTAssertTrue(rows[0].userEdited)

        // A re-sync recompute (userEdited=false, startTsAdjusted nil incoming) must preserve the onset edit.
        try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: 0.95,
                                restingHr: 49, avgHrv: 71, stagesJSON: "[\"resync\"]")],
            deviceId: "devA")
        rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows[0].startTsAdjusted, 1300, "onset edit survives re-sync")
        XCTAssertEqual(rows[0].endTs, 4200, "wake edit survives re-sync")
        XCTAssertEqual(rows[0].stagesJSON, "[\"restaged\"]")
        XCTAssertEqual(rows[0].efficiency, 0.95, "vitals still refresh")
    }

    /// The crux of the feature: once a user has corrected a night's wake time, the next strap sync's
    /// recompute (which re-upserts the strap-detected session over the same natural key with
    /// `userEdited == false`) must NOT revert the corrected `endTs` or clear the flag — but it MAY still
    /// refresh the derived vitals (efficiency / restingHr / avgHrv).
    func testRecomputeUpsertPreservesUserEditedBounds() async throws {
        let store = try await WhoopStore.inMemory()
        // Strap-detected session, then the user corrects the wake time 800s earlier.
        try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: 0.90,
                                restingHr: 52, avgHrv: 60, stagesJSON: "[\"orig\"]")],
            deviceId: "devA")
        try await store.applySleepEdit(deviceId: "devA", detectedStartTs: 1000, newStartTs: 1000, newEndTs: 4200)

        // Simulate the next sync re-running the stager: same (deviceId, startTs), strap's ORIGINAL
        // endTs back again, fresh vitals, userEdited defaulting false.
        try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: 0.95,
                                restingHr: 49, avgHrv: 71, stagesJSON: "[\"resync\"]")],
            deviceId: "devA")

        let rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].endTs, 4200, "user-corrected wake time survives the re-sync")
        XCTAssertTrue(rows[0].userEdited, "the edit flag is not cleared by a recompute upsert")
        XCTAssertEqual(rows[0].stagesJSON, "[\"orig\"]", "edited session keeps its stage breakdown")
        // Derived vitals are still allowed to refresh from the denser post-sync data.
        XCTAssertEqual(rows[0].efficiency, 0.95)
        XCTAssertEqual(rows[0].restingHr, 49)
        XCTAssertEqual(rows[0].avgHrv, 71)
    }

    func testRecomputeUpsertStillOverwritesUnEditedSession() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: 1000, endTs: 5000, efficiency: 0.90,
                                restingHr: 52, avgHrv: 60, stagesJSON: "[\"orig\"]")],
            deviceId: "devA")
        // No user edit → a re-upsert behaves exactly as before (strap value wins).
        try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: 1000, endTs: 6000, efficiency: 0.95,
                                restingHr: 49, avgHrv: 71, stagesJSON: "[\"resync\"]")],
            deviceId: "devA")
        let rows = try await store.sleepSessions(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].endTs, 6000)
        XCTAssertEqual(rows[0].stagesJSON, "[\"resync\"]")
        XCTAssertFalse(rows[0].userEdited)
    }

    // MARK: - daily metrics

    func testDailyMetricUpsertReadAndIdempotency() async throws {
        let store = try await WhoopStore.inMemory()
        let d = DailyMetric(day: "2026-05-23", totalSleepMin: 420.0, efficiency: 0.9,
                            deepMin: 90, remMin: 110, lightMin: 220, disturbances: 3,
                            restingHr: 53, avgHrv: 60.0, recovery: 0.66, strain: 12.3, exerciseCount: 1)
        try await store.upsertDailyMetrics([d], deviceId: "devA")

        var rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], d)

        // Re-upsert same day with new values → no duplicate, value updated.
        let d2 = DailyMetric(day: "2026-05-23", totalSleepMin: 400.0, efficiency: 0.88,
                             deepMin: 80, remMin: 100, lightMin: 220, disturbances: 5,
                             restingHr: 55, avgHrv: 58.0, recovery: 0.6, strain: 14.0, exerciseCount: 2)
        try await store.upsertDailyMetrics([d2], deviceId: "devA")
        rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1, "same (deviceId,day) must not duplicate")
        XCTAssertEqual(rows[0], d2)
    }

    func testDailyMetricDayRangeFilter() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([
            DailyMetric(day: "2026-05-01", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil),
            DailyMetric(day: "2026-05-20", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil),
        ], deviceId: "devA")
        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-10", to: "2026-05-31")
        XCTAssertEqual(rows.map { $0.day }, ["2026-05-20"])
    }

    // MARK: - windowed computed-daily delete (#277 local-day re-bucketing migration)

    func testDeleteDailyMetricsInRangeKeepsImportedAndOutOfRange() async throws {
        let store = try await WhoopStore.inMemory()
        let bare: (String) -> DailyMetric = { day in
            DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: nil, strain: nil, exerciseCount: nil)
        }
        // Computed source ("my-whoop-noop"): four days, three inside [2026-05-10, 2026-05-12].
        try await store.upsertDailyMetrics(
            [bare("2026-05-09"), bare("2026-05-10"), bare("2026-05-11"), bare("2026-05-12")],
            deviceId: "my-whoop-noop")
        // Imported source ("my-whoop"): a day INSIDE the range that must survive.
        try await store.upsertDailyMetrics([bare("2026-05-11")], deviceId: "my-whoop")

        let deleted = try await store.deleteDailyMetrics(
            deviceId: "my-whoop-noop", from: "2026-05-10", to: "2026-05-12")
        XCTAssertEqual(deleted, 3, "only the 3 in-range computed rows are removed")

        // Computed: only the out-of-range 2026-05-09 row remains.
        let computed = try await store.dailyMetrics(
            deviceId: "my-whoop-noop", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(computed.map { $0.day }, ["2026-05-09"])
        // Imported row inside the range is untouched (BLE-only users keep no fallback, imports win).
        let imported = try await store.dailyMetrics(
            deviceId: "my-whoop", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(imported.map { $0.day }, ["2026-05-11"])
    }

    // MARK: - v7 in-sleep signal columns (spo2Pct / skinTempDevC / respRateBpm)

    func testV7ColumnsRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        let d = DailyMetric(day: "2026-05-26", totalSleepMin: 420, efficiency: 0.91,
                            deepMin: 90, remMin: 110, lightMin: 220, disturbances: 2,
                            restingHr: 52, avgHrv: 63.0, recovery: 0.70, strain: 11.5,
                            exerciseCount: 1, spo2Pct: 96.4, skinTempDevC: 0.3, respRateBpm: 15.2)
        try await store.upsertDailyMetrics([d], deviceId: "devA")

        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(try XCTUnwrap(row.spo2Pct), 96.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.skinTempDevC), 0.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.respRateBpm), 15.2, accuracy: 0.001)
    }

    func testV7ColumnsNilWhenAbsent() async throws {
        let store = try await WhoopStore.inMemory()
        // Omit the three new params — they default to nil.
        let d = DailyMetric(day: "2026-05-25", totalSleepMin: nil, efficiency: nil,
                            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                            restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
        try await store.upsertDailyMetrics([d], deviceId: "devA")

        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].spo2Pct)
        XCTAssertNil(rows[0].skinTempDevC)
        XCTAssertNil(rows[0].respRateBpm)
    }

    func testV7UpsertUpdatesNewColumns() async throws {
        let store = try await WhoopStore.inMemory()
        // Insert with nil new columns.
        let d1 = DailyMetric(day: "2026-05-24", totalSleepMin: 400, efficiency: 0.88,
                             deepMin: 80, remMin: 100, lightMin: 220, disturbances: 3,
                             restingHr: 54, avgHrv: 60.0, recovery: 0.65, strain: 13.0, exerciseCount: 0)
        try await store.upsertDailyMetrics([d1], deviceId: "devA")

        // Re-upsert same day with new-column values populated.
        let d2 = DailyMetric(day: "2026-05-24", totalSleepMin: 400, efficiency: 0.88,
                             deepMin: 80, remMin: 100, lightMin: 220, disturbances: 3,
                             restingHr: 54, avgHrv: 60.0, recovery: 0.65, strain: 13.0, exerciseCount: 0,
                             spo2Pct: 97.1, skinTempDevC: -0.1, respRateBpm: 14.8)
        try await store.upsertDailyMetrics([d2], deviceId: "devA")

        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1, "upsert must not duplicate")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(try XCTUnwrap(row.spo2Pct), 97.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.skinTempDevC), -0.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.respRateBpm), 14.8, accuracy: 0.001)
    }

    // MARK: - v11 daily-activity columns (steps / activeKcalEst)

    func testV11ColumnsPresent() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "dailyMetric")
        XCTAssertTrue(cols.contains("steps"), "dailyMetric missing v11 steps column")
        XCTAssertTrue(cols.contains("activeKcalEst"), "dailyMetric missing v11 activeKcalEst column")
    }

    func testV11ColumnsRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        let d = DailyMetric(day: "2026-05-27", totalSleepMin: 410, efficiency: 0.9,
                            deepMin: 85, remMin: 105, lightMin: 220, disturbances: 2,
                            restingHr: 51, avgHrv: 64.0, recovery: 0.72, strain: 10.9,
                            exerciseCount: 1, spo2Pct: 96.0, skinTempDevC: 0.1, respRateBpm: 14.9,
                            steps: 8_412, activeKcalEst: 2_310.5)
        try await store.upsertDailyMetrics([d], deviceId: "devA")

        let rows = try await store.dailyMetrics(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.steps, 8_412)
        XCTAssertEqual(try XCTUnwrap(row.activeKcalEst), 2_310.5, accuracy: 0.001)
        // Omitting the new params keeps them nil (defaulted init, old call sites unchanged).
        let bare = DailyMetric(day: "2026-05-28", totalSleepMin: nil, efficiency: nil,
                               deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                               restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
        try await store.upsertDailyMetrics([bare], deviceId: "devA")
        let bareRows = try await store.dailyMetrics(
            deviceId: "devA", from: "2026-05-28", to: "2026-05-28")
        let bareRow = try XCTUnwrap(bareRows.first)
        XCTAssertNil(bareRow.steps)
        XCTAssertNil(bareRow.activeKcalEst)
    }

    // MARK: - read highwater cursor (distinct prefix from upload highwater)

    func testReadHighwaterRoundTripsUnderDistinctPrefix() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await store.readHighwater("hr")
        XCTAssertNil(before)
        try await store.setReadHighwater("hr", 1_716_400_000)
        let after = try await store.readHighwater("hr")
        XCTAssertEqual(after, 1_716_400_000)
        // Distinct from the upload highwater for the same stream.
        try await store.setHighwater("hr", 42)
        let uploadHW = try await store.highwater("hr")
        let readHW = try await store.readHighwater("hr")
        XCTAssertEqual(uploadHW, 42)
        XCTAssertEqual(readHW, 1_716_400_000)
        // Raw rows are stored under the distinct prefix.
        let raw = try await store.cursor("read:hr")
        XCTAssertEqual(raw, 1_716_400_000)
    }
}
