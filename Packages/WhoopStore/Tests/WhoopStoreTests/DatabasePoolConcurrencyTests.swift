import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// #755: `WhoopStore` opens its file-backed connection as a GRDB `DatabasePool` (WAL) so the
/// dashboard's reads run CONCURRENTLY with the backfill's bulk writes instead of serializing behind
/// them on a single `DatabaseQueue`. These tests prove (a) a file-backed store round-trips writes and
/// reads unchanged, and (b) a read issued WHILE a write transaction is still open returns the
/// last-committed snapshot immediately, rather than blocking until the writer commits.
final class DatabasePoolConcurrencyTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "whoopstore-pool-\(UUID().uuidString).sqlite"
    }

    private func removeDB(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// The file-backed store (now Pool-backed) writes then reads the same rows back unchanged:
    /// the migration from Queue to Pool must not alter any stored data or query result.
    func testFileBackedStoreWritesAndReadsBackUnchanged() async throws {
        let path = tempPath()
        defer { removeDB(path) }

        let store = try await WhoopStore(path: path)
        let streams = Streams(hr: [
            HRSample(ts: 1_000, bpm: 60),
            HRSample(ts: 1_001, bpm: 61),
            HRSample(ts: 1_002, bpm: 62),
        ])
        let inserted = try await store.insert(streams, deviceId: "dev")
        XCTAssertEqual(inserted.hr, 3)

        let counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 3, "rows written via the Pool must read back identically")
    }

    /// CORE #755 ASSERTION: under a `DatabasePool`, a read started while a write transaction is
    /// still open does NOT block on the writer; it returns the last committed snapshot at once.
    ///
    /// The writer task opens a `.write`, signals that it is inside the transaction, then parks on a
    /// semaphore (simulating a long backfill chunk). A second task issues a `.read`; with a serial
    /// `DatabaseQueue` that read would be stuck behind the open write, but a Pool serves it from the
    /// WAL snapshot. We assert the read finishes (returns the pre-write committed value) BEFORE we
    /// release the writer. Then, after the writer commits, a fresh read sees the new value, proving
    /// reads still observe only committed data, never a partial write.
    func testConcurrentReadDuringOpenWriteReturnsCommittedData() async throws {
        let path = tempPath()
        defer { removeDB(path) }

        // Open the same configuration the store uses (WAL via Pool) directly so the test can hold a
        // write transaction open and observe a concurrent read. A single shared seed row is committed
        // first so the snapshot read has a known committed value.
        var config = Configuration()
        config.busyMode = .timeout(5)
        let pool = try DatabasePool(path: path, configuration: config)
        try await pool.write { db in
            try db.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO t (id, v) VALUES (1, 100)")
        }

        let insideWrite = DispatchSemaphore(value: 0)   // writer → test: transaction is open
        let releaseWrite = DispatchSemaphore(value: 0)   // test → writer: you may commit now

        // Long writer: opens a transaction, mutates the row, signals, then parks until released.
        let writer = Task.detached {
            try pool.write { db in
                try db.execute(sql: "UPDATE t SET v = 200 WHERE id = 1")
                insideWrite.signal()
                releaseWrite.wait()   // hold the write transaction open
            }
        }

        // Wait until the writer is provably inside its open transaction.
        XCTAssertEqual(insideWrite.wait(timeout: .now() + 5), .success,
                       "writer never entered its transaction")

        // Concurrent read WHILE the write is still open. On a Pool this returns the last committed
        // snapshot (v = 100) immediately; on a serial Queue it would block until the writer commits.
        let snapshotValue = try await withThrowingTaskGroup(of: Int.self) { group -> Int in
            group.addTask {
                try pool.read { db in
                    try Int.fetchOne(db, sql: "SELECT v FROM t WHERE id = 1") ?? -1
                }
            }
            // Bound the read so a regression (read blocking on the writer) fails fast instead of
            // hanging the suite: the read must complete while the writer is still parked.
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw ConcurrencyTimeout.readBlockedOnWriter
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertEqual(snapshotValue, 100,
                       "a concurrent read during an open write must see the committed snapshot (100), not the uncommitted 200")

        // Release the writer, let it commit, and confirm a subsequent read sees the new value:
        // reads observe committed data, just without serializing behind the writer.
        releaseWrite.signal()
        try await writer.value
        let committedValue = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT v FROM t WHERE id = 1") ?? -1
        }
        XCTAssertEqual(committedValue, 200, "after the writer commits, reads must see the new value")
    }

    /// #755 review finding-1: every OTHER store test uses `inMemory()` (a `DatabaseQueue`) or, above, a
    /// bare `Configuration()`, so none drive the production `init(path:)` config. Its `prepareDatabase`
    /// PRAGMA block (synchronous/cache_size/mmap_size/temp_store) must run on EVERY connection a Pool
    /// opens, the writer AND each reader, not just once. This opens the REAL store and reads
    /// `PRAGMA cache_size` + `journal_mode` back off a pooled reader connection: `-16000` and `wal`
    /// prove `prepareDatabase` applied per-connection, closing the inMemory/Queue blind spot the
    /// migration's read/write concurrency depends on (a writer-only pragma would be the classic footgun).
    func testProductionPoolRunsPrepareDatabaseOnReaderConnections() async throws {
        let path = tempPath()
        defer { removeDB(path) }

        let store = try await WhoopStore(path: path)
        let pool = store.registryWriter   // the production-configured DatabasePool

        // A `.read` runs on a pooled reader connection; cache_size reflects its prepareDatabase pragma.
        let cacheSize = try await pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA cache_size") ?? 0
        }
        XCTAssertEqual(cacheSize, -16000,
                       "production prepareDatabase pragmas must apply on pooled reader connections, not just the writer")

        let journalMode = try await pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
        XCTAssertEqual(journalMode.lowercased(), "wal", "DatabasePool must put the file in WAL mode")
    }

    private enum ConcurrencyTimeout: Error { case readBlockedOnWriter }
}
