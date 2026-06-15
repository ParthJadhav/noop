import Foundation
import GRDB

/// Synchronous GRDB access to the device registry + day-ownership tables. Kept synchronous (its own
/// queue) to mirror the existing store helpers; the app wraps it behind the WhoopStore actor / a
/// @MainActor cache. Enforces invariant I1 (at most one .active) inside setActive's transaction.
public struct DeviceRegistryStore {
    let dbQueue: DatabaseQueue
    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

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
            INSERT INTO pairedDevice (id, brand, model, nickname, sourceKind, capabilities, status, addedAt, lastSeenAt)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET brand=excluded.brand, model=excluded.model, nickname=excluded.nickname,
                sourceKind=excluded.sourceKind, capabilities=excluded.capabilities, status=excluded.status,
                lastSeenAt=excluded.lastSeenAt
        """, arguments: [d.id, d.brand, d.model, d.nickname, d.sourceKind.rawValue,
                         d.capabilities.map(\.rawValue).sorted().joined(separator: ","),
                         d.status.rawValue, d.addedAt, d.lastSeenAt])
    }

    private static func decode(_ row: Row) -> PairedDevice {
        let caps = (row["capabilities"] as String).split(separator: ",").compactMap { Metric(rawValue: String($0)) }
        return PairedDevice(id: row["id"], brand: row["brand"], model: row["model"], nickname: row["nickname"],
                            sourceKind: SourceKind(rawValue: row["sourceKind"]) ?? .liveBLE,
                            capabilities: Set(caps), status: DeviceStatus(rawValue: row["status"]) ?? .paired,
                            addedAt: row["addedAt"], lastSeenAt: row["lastSeenAt"])
    }
}
