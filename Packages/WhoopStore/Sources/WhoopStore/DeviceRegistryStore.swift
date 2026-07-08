import Foundation
import GRDB

/// Synchronous GRDB access to the device registry + day-ownership tables. Kept synchronous (its own
/// queue) to mirror the existing store helpers; the app wraps it behind the WhoopStore actor / a
/// @MainActor cache. Enforces invariant I1 (at most one .active) inside setActive's transaction.
///
/// `Sendable`: the only stored property is a GRDB `DatabaseWriter` (a `DatabasePool` in production;
/// the protocol refines `Sendable` and manages its own concurrency), so this thin synchronous wrapper
/// is safe to hand across actor boundaries, e.g. the off-main `IntelligenceEngine.analyzeRecent` scan
/// loop (FIX 1). A cross-module `public` struct doesn't auto-infer `Sendable`, so it's declared here.
///
/// Takes `any DatabaseWriter` (not the concrete `DatabaseQueue`) so it works with the store's
/// `DatabasePool` (#755) AND a plain `DatabaseQueue` (in-memory tests) unchanged: both expose the
/// same synchronous `.read`/`.write` API used below.
public struct DeviceRegistryStore: Sendable {
    let dbQueue: any DatabaseWriter
    public init(dbQueue: any DatabaseWriter) { self.dbQueue = dbQueue }

    public func all() throws -> [PairedDevice] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pairedDevice ORDER BY addedAt ASC").map(Self.decode)
        }
    }

    public func activeDeviceId() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM pairedDevice WHERE status = 'active' LIMIT 1")
        }
    }

    public func add(_ d: PairedDevice) throws {
        try dbQueue.write { db in try Self.upsert(db, d) }
    }

    /// I1: promoting one device demotes whatever was active, atomically (single write transaction).
    public func setActive(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET status = 'paired' WHERE status = 'active'")
            try db.execute(sql: "UPDATE pairedDevice SET status = 'active', lastSeenAt = ? WHERE id = ?",
                           arguments: [Int(Date().timeIntervalSince1970), id])
        }
    }

    public func archive(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET status = 'archived' WHERE id = ?", arguments: [id])
        }
    }

    public func rename(_ id: String, nickname: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET nickname = ? WHERE id = ?", arguments: [nickname, id])
        }
    }

    /// Adopt (or clear) the stable BLE identity for a registry row. `peripheralId` is the
    /// CBPeripheral.identifier.uuidString on iOS/Mac; passing nil un-adopts it.
    public func setPeripheralId(_ id: String, peripheralId: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET peripheralId = ? WHERE id = ?",
                           arguments: [peripheralId, id])
        }
    }

    /// Find the registry row that has adopted a given BLE peripheral, if any. Used to map a
    /// connected CBPeripheral back to its `PairedDevice` so multiple straps stay distinct.
    public func device(forPeripheralId peripheralId: String) throws -> PairedDevice? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM pairedDevice WHERE peripheralId = ? LIMIT 1",
                             arguments: [peripheralId]).map(Self.decode)
        }
    }

    /// Every table whose rows are keyed by `deviceId` (the per-device sample/derived tables). This is
    /// the authoritative list `deleteAllData` clears — kept in sync with the `deviceId`-keyed tables in
    /// `Database.swift`. The `pairedDevice` registry row itself is NOT here (a delete-data operation
    /// empties the device's recordings; archiving/removing the registry entry is a separate op).
    static let deviceScopedTables = [
        "hrSample", "rrInterval", "spo2Sample", "skinTempSample", "respSample", "gravitySample",
        "stepSample", "ppgHrSample", "event", "battery", "dailyMetric", "sleepSession",
        "journal", "workout", "appleDaily", "metricSeries", "dayOwnership",
    ]

    /// Permanently delete every recorded sample/derived row belonging to one device, across all
    /// `deviceId`-keyed tables, in a single transaction (all-or-nothing). The `pairedDevice` registry
    /// row is left intact — the caller archives/removes that separately. Tables are deleted defensively
    /// with `DELETE FROM <table> WHERE deviceId = ?`; a missing table would throw, but every table here
    /// is created unconditionally by the migrator, so the set is stable.
    public func deleteAllData(deviceId: String) throws {
        try dbQueue.write { db in
            for table in Self.deviceScopedTables {
                try db.execute(sql: "DELETE FROM \(table) WHERE deviceId = ?", arguments: [deviceId])
            }
        }
    }

    // MARK: day ownership
    public struct DayOwner: Equatable { public let deviceId: String; public let locked: Bool }

    public func setDayOwner(day: String, deviceId: String, locked: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked) VALUES (?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET deviceId = excluded.deviceId, locked = excluded.locked
            """, arguments: [day, deviceId, locked ? 1 : 0])
        }
    }

    public func dayOwner(_ day: String) throws -> DayOwner? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT deviceId, locked FROM dayOwnership WHERE day = ?", arguments: [day])
            else { return nil }
            return DayOwner(deviceId: row["deviceId"], locked: (row["locked"] as Int) == 1)
        }
    }

    // MARK: mapping
    private static func upsert(_ db: Database, _ d: PairedDevice) throws {
        try db.execute(sql: """
            INSERT INTO pairedDevice (id, brand, model, nickname, peripheralId, sourceKind, capabilities, status, addedAt, lastSeenAt)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET brand=excluded.brand, model=excluded.model, nickname=excluded.nickname,
                peripheralId=excluded.peripheralId, sourceKind=excluded.sourceKind, capabilities=excluded.capabilities,
                status=excluded.status, lastSeenAt=excluded.lastSeenAt
        """, arguments: [d.id, d.brand, d.model, d.nickname, d.peripheralId, d.sourceKind.rawValue,
                         d.capabilities.map(\.rawValue).sorted().joined(separator: ","),
                         d.status.rawValue, d.addedAt, d.lastSeenAt])
    }

    private static func decode(_ row: Row) -> PairedDevice {
        let caps = (row["capabilities"] as String).split(separator: ",").compactMap { Metric(rawValue: String($0)) }
        return PairedDevice(id: row["id"], brand: row["brand"], model: row["model"], nickname: row["nickname"],
                            peripheralId: row["peripheralId"],
                            sourceKind: SourceKind(rawValue: row["sourceKind"]) ?? .liveBLE,
                            capabilities: Set(caps), status: DeviceStatus(rawValue: row["status"]) ?? .paired,
                            addedAt: row["addedAt"], lastSeenAt: row["lastSeenAt"])
    }
}
