import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// v21 migration (#175): the strap's OWN band sleep_state stream persistence — the @81 high-nibble state
/// (0 wake/1 still/2 asleep/3 up) was decoded but DROPPED at storage, so the band-state chain (the H7
/// re-onset confirm guard + the Deep Timeline track) had no source. This proves the table exists, keys by
/// (deviceId, ts), and round-trips + dedupes exactly like stepSample.
final class SleepStateSampleTests: XCTestCase {
    func testV21CreatesSleepStateTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("sleepStateSample"))
    }

    func testSleepStatePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("sleepStateSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    /// The raw stream round-trips through insert + read, INCLUDING state 0 (a real wake reading, not
    /// "absent"), and re-inserting the same (deviceId, ts) is idempotent (ON CONFLICT DO NOTHING).
    func testSleepStateInsertRoundTripAndDedup() async throws {
        let store = try await WhoopStore.inMemory()
        let streams = Streams(sleepState: [
            SleepStateSample(ts: 1_780_916_150, state: 0),   // wake (real, carried verbatim)
            SleepStateSample(ts: 1_780_916_180, state: 1),   // still
            SleepStateSample(ts: 1_780_916_210, state: 2),   // asleep
            SleepStateSample(ts: 1_780_916_240, state: 3),   // up
        ])
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n1 = try await store.sleepStateCountForTest()
        XCTAssertEqual(n1, 4)

        let read = try await store.sleepStateSamples(deviceId: "my-whoop",
                                                     from: 1_780_916_150, to: 1_780_916_240)
        XCTAssertEqual(read, streams.sleepState, "every band code (incl. 0) round-trips in ts order")

        // Idempotent re-sync: the same second keeps its first-seen state, no duplicate rows.
        _ = try await store.insert(streams, deviceId: "my-whoop")
        let n2 = try await store.sleepStateCountForTest()
        XCTAssertEqual(n2, 4)
    }

    /// The read is device-scoped and range-scoped: another device's band state never leaks in, and a
    /// window that predates the samples returns empty (a strap that never reported it → no rows).
    func testSleepStateReadIsDeviceAndRangeScoped() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(sleepState: [SleepStateSample(ts: 2_000, state: 2)]),
                                   deviceId: "my-whoop")
        _ = try await store.insert(Streams(sleepState: [SleepStateSample(ts: 2_000, state: 3)]),
                                   deviceId: "other-device")
        let mine = try await store.sleepStateSamples(deviceId: "my-whoop", from: 0, to: 10_000)
        XCTAssertEqual(mine, [SleepStateSample(ts: 2_000, state: 2)])
        let outOfRange = try await store.sleepStateSamples(deviceId: "my-whoop", from: 5_000, to: 10_000)
        XCTAssertTrue(outOfRange.isEmpty)
    }
}
