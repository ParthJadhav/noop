import Foundation
import GRDB
import WhoopProtocol

/// One downsampled heart-rate point: the bucket's start (unix seconds) and the mean bpm over it.
/// Returned by the `GROUP BY ts/bucket` aggregate so a day chart plots ~N-minute means instead of
/// loading the raw ~1 Hz rows (a fully-worn 24h is ~86k samples).
public struct HRBucket: Sendable, Equatable {
    public let ts: Int
    public let bpm: Double
    public init(ts: Int, bpm: Double) { self.ts = ts; self.bpm = bpm }
}

extension WhoopStore {
    /// Shared decoder, JSONDecoder is stateless across decodes and was previously allocated once
    /// per event row. Battery events are dense (~every 8 min), so a multi-year read decodes
    /// thousands of rows; reusing one decoder removes that per-row allocation.
    fileprivate static let eventDecoder = JSONDecoder()

    /// Raw HR samples over `[from, to]`, measured-first with PPG-derived fallback.
    ///
    /// COALESCEs the measured `hrSample` with the v26 PPG-derived `ppgHrSample` (#156) using the same
    /// anti-join as `hrBuckets`: every measured second wins, and any second with NO hrSample row falls
    /// back to its PPG estimate (never doubling a beat). This keeps the raw read in lockstep with the
    /// chart path, and lets a PPG-only WHOOP 5 night clear the night-stager's HR-count gate so it is
    /// scorable (#172). The PPG `bpm` is REAL, so it is ROUND-ed to the `HRSample.bpm` Int domain.
    public func hrSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [HRSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM (
                    SELECT ts, bpm FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION ALL
                    SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER) AS bpm FROM ppgHrSample p
                    WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                      AND NOT EXISTS (
                        SELECT 1 FROM hrSample h
                        WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                )
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to,
                                 deviceId, from, to,
                                 limit])
                .map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        }
    }

    /// Cheap change-detector for the raw HR stream: `(count, maxTs)` over `[from, to]`, computed in
    /// SQLite over the `(deviceId, ts)` index WITHOUT materializing any rows (#836). Lets a caller decide
    /// "nothing was inserted since last time, skip the expensive re-read" for pennies, `COUNT(*)` moves on
    /// any insert (including a backfilled OLD night whose `maxTs` wouldn't change), and `maxTs` distinguishes
    /// fresh appends. COALESCE so an empty window is `(0, 0)`, never nil.
    public func hrFingerprint(deviceId: String, from: Int, to: Int) async throws -> (count: Int, maxTs: Int) {
        try syncRead { db in
            // COUNT(*) and COALESCE(MAX(ts),0) are both NON-NULL, and the aggregate query always returns
            // exactly one row, so fetchOne is non-nil and the columns read straight into Int. The guard is
            // belt-and-suspenders.
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM hrSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                """, arguments: [deviceId, from, to]) else { return (0, 0) }
            let c: Int = row["c"]
            let m: Int = row["m"]
            return (c, m)
        }
    }

    /// Downsampled HR for charting: mean bpm per `bucketSeconds`-wide bucket over `[from, to]`,
    /// keyed by the bucket's start (floor(ts/bucket)*bucket). Aggregates in SQL so a 24h window
    /// returns ~`(to-from)/bucketSeconds` rows instead of every ~1 Hz sample. Ascending by time.
    ///
    /// COALESCEs the measured `hrSample` with the v26 PPG-derived `ppgHrSample` (#156): every measured
    /// second wins, and any second with NO hrSample row falls back to its PPG estimate so the chart
    /// stays continuous through v26-heavy stretches. The fallback rows are `bpm REAL` and only appear
    /// where the device genuinely had no measured HR for that second (anti-join), never doubling a beat.
    public func hrBuckets(deviceId: String, from: Int, to: Int, bucketSeconds: Int) async throws -> [HRBucket] {
        let bucket = max(1, bucketSeconds)
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT (ts / ?) * ? AS bucket, AVG(bpm) AS avgBpm FROM (
                    SELECT ts, bpm FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION ALL
                    SELECT p.ts, p.bpm FROM ppgHrSample p
                    WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                      AND NOT EXISTS (
                        SELECT 1 FROM hrSample h
                        WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                )
                GROUP BY ts / ?
                ORDER BY bucket ASC
                """, arguments: [bucket, bucket,
                                 deviceId, from, to,
                                 deviceId, from, to,
                                 bucket])
                .map { HRBucket(ts: $0["bucket"], bpm: $0["avgBpm"]) }
        }
    }

    public func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RRInterval] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, rrMs FROM rrInterval
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC, rrMs ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { RRInterval(ts: $0["ts"], rrMs: $0["rrMs"]) }
        }
    }

    public func events(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [WhoopEvent] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, kind, payloadJSON FROM event
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC, kind ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { row in
                    let json: String = row["payloadJSON"]
                    let payload = (try? WhoopStore.eventDecoder.decode(
                        [String: ParsedValue].self,
                        from: Data(json.utf8))) ?? [:]
                    return WhoopEvent(ts: row["ts"], kind: row["kind"], payload: payload)
                }
        }
    }

    public func batterySamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [BatterySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, soc, mv FROM battery
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { BatterySample(ts: $0["ts"], soc: $0["soc"], mv: $0["mv"]) }
        }
    }

    public func spo2Samples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [SpO2Sample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, red, ir FROM spo2Sample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { SpO2Sample(ts: $0["ts"], red: $0["red"], ir: $0["ir"]) }
        }
    }

    public func skinTempSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [SkinTempSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM skinTempSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { SkinTempSample(ts: $0["ts"], raw: $0["raw"]) }
        }
    }

    public func stepSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [StepSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, counter, activityClass FROM stepSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // activityClass (#316, v19) reads back nil for any pre-v19 row (the column defaulted null) and
                // for any record whose @63 byte was 0xFF/invalid/absent, an absent class stays absent.
                .map { StepSample(ts: $0["ts"], counter: $0["counter"], activityClass: $0["activityClass"]) }
        }
    }

    public func respSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RespSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM respSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { RespSample(ts: $0["ts"], raw: $0["raw"]) }
        }
    }

    public func gravitySamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [GravitySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, x, y, z FROM gravitySample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { GravitySample(ts: $0["ts"], x: $0["x"], y: $0["y"], z: $0["z"]) }
        }
    }

    /// Max HR sample timestamp for a device, or nil if there are none. The biometric "data frontier"
    /// used by the stuck-strap watchdog (advances iff the strap is actually logging + offloading).
    ///
    /// Coalesces measured `hrSample` with PPG-derived `ppgHrSample` (#156) so a PPG-only offload (a v26
    /// WHOOP 5 night with no measured HR) still advances the frontier. The two persist in the same
    /// offload, so this only ever moves the watchdog forward when the strap really logged + offloaded.
    public func latestHRSampleTs(deviceId: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT MAX(ts) FROM (
                    SELECT ts FROM hrSample WHERE deviceId = ?
                    UNION ALL
                    SELECT ts FROM ppgHrSample WHERE deviceId = ?
                )
                """, arguments: [deviceId, deviceId])
        }
    }

    /// Aggregate storage footprint: total decoded rows, raw batch count, total raw byteSize.
    public func storageStats() async throws -> (decodedRows: Int, rawBatches: Int, rawBytes: Int) {
        try syncRead { db in
            let hr   = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0
            let rr   = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0
            let ev   = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
            let bat  = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0
            let spo2 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spo2Sample") ?? 0
            let skin = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skinTempSample") ?? 0
            let resp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM respSample") ?? 0
            let grav = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gravitySample") ?? 0
            let batches = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch") ?? 0
            let bytes   = try Int.fetchOne(db,
                sql: "SELECT COALESCE(SUM(byteSize), 0) FROM rawBatch") ?? 0
            return (hr + rr + ev + bat + spo2 + skin + resp + grav, batches, bytes)
        }
    }
}
