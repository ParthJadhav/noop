import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v10 migration: WHOOP5 step_motion_counter persistence (macOS parity with Android, #78).
final class StepSampleTests: XCTestCase {
    func testV10CreatesStepTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("stepSample"))
    }

    func testStepPrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("stepSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    func testStepInsertRoundTripAndDedup() async throws {
        let store = try await WhoopStore.inMemory()
        let streams = Streams(steps: [
            StepSample(ts: 1_780_916_150, counter: 50),
            StepSample(ts: 1_780_916_151, counter: 51),
        ])
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n1 = try await store.stepCountForTest()
        XCTAssertEqual(n1, 2)
        // Re-inserting the same (deviceId, ts) is idempotent, ON CONFLICT DO NOTHING.
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n2 = try await store.stepCountForTest()
        XCTAssertEqual(n2, 2)
    }

    /// v19 migration: the @63 activity-class column exists on stepSample (#316).
    func testV19AddsActivityClassColumn() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "stepSample")
        XCTAssertTrue(cols.contains("activityClass"))
    }

    /// #316, a step sample's `activityClass` (0=still / 1=walk / 2=run) survives a write+read round-trip,
    /// and a nil class (the @63 byte was 0xFF/invalid/absent) round-trips back as nil (an absent class stays
    /// absent, never a fabricated 0/"still"). This is the chain the tigercraft4 PR #901 botched on Apple:
    /// it SELECTed a column that didn't exist. Here the v19 migration + INSERT + SELECT carry it end to end.
    func testActivityClassRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        let streams = Streams(steps: [
            StepSample(ts: 1_780_916_200, counter: 60, activityClass: 0),   // still
            StepSample(ts: 1_780_916_201, counter: 61, activityClass: 1),   // walk
            StepSample(ts: 1_780_916_202, counter: 62, activityClass: 2),   // run
            StepSample(ts: 1_780_916_203, counter: 63, activityClass: nil), // no class (0xFF/invalid/absent)
        ])
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let read = try await store.stepSamples(deviceId: "my-whoop",
                                               from: 1_780_916_200, to: 1_780_916_203, limit: 100)
        XCTAssertEqual(read.count, 4)
        XCTAssertEqual(read.map(\.activityClass), [0, 1, 2, nil])
        // The counter rides through unchanged alongside the new column.
        XCTAssertEqual(read.map(\.counter), [60, 61, 62, 63])
    }
}
