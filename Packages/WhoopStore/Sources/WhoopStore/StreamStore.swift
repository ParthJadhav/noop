import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Deterministic JSON for an event payload (sorted keys so the same payload always
    /// serializes byte-identically, important for the natural-key dedupe and parity).
    static func encodePayload(_ payload: [String: ParsedValue]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// Insert or update a device row (natural key = id).
    public func upsertDevice(id: String, mac: String?, name: String?) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    mac = excluded.mac,
                    name = excluded.name,
                    lastSeen = excluded.lastSeen
                """, arguments: [id, mac, name, now, now])
        }
    }

    /// Idempotent upsert of decoded streams by natural key. Returns the number of rows
    /// ACTUALLY inserted per stream (0 for rows that already existed).
    ///
    /// NOTE: the `synced` column (added by migration v5 for a since-removed server-upload feature)
    /// is intentionally NOT written here, it is unused and defaults to 0. The column is left in the
    /// schema to avoid a DROP COLUMN migration over existing data; nothing reads it.
    @discardableResult
    public func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        return try syncWrite { db in
            var hr = 0, rr = 0, ev = 0, bat = 0
            var spo2 = 0, skin = 0, resp = 0, grav = 0
            // Reuse one prepared statement per table instead of recompiling the same SQL on every
            // row. This is the hottest write path (every Collector.flush + every Backfiller chunk
            // over potentially millions of historical rows). cachedStatement persists the compiled
            // statement on the connection across insert() calls too. Each loop is guarded so empty
            // streams (the common live case) compile nothing.
            if !streams.hr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.hr {
                    try stmt.execute(arguments: [deviceId, s.ts, s.bpm])
                    hr += db.changesCount
                }
            }
            if !streams.rr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO rrInterval (deviceId, ts, rrMs) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts, rrMs) DO NOTHING
                    """)
                for r in streams.rr {
                    try stmt.execute(arguments: [deviceId, r.ts, r.rrMs])
                    rr += db.changesCount
                }
            }
            if !streams.events.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, kind) DO NOTHING
                    """)
                for e in streams.events {
                    let json = try WhoopStore.encodePayload(e.payload)
                    try stmt.execute(arguments: [deviceId, e.ts, e.kind, json])
                    ev += db.changesCount
                }
            }
            if !streams.battery.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv, charging) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for b in streams.battery {
                    try stmt.execute(arguments: [deviceId, b.ts, b.soc, b.mv, b.charging])
                    bat += db.changesCount
                }
            }
            if !streams.spo2.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO spo2Sample (deviceId, ts, red, ir) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.spo2 {
                    try stmt.execute(arguments: [deviceId, s.ts, s.red, s.ir])
                    spo2 += db.changesCount
                }
            }
            if !streams.skinTemp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO skinTempSample (deviceId, ts, raw) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.skinTemp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw])
                    skin += db.changesCount
                }
            }
            if !streams.resp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO respSample (deviceId, ts, raw) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.resp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw])
                    resp += db.changesCount
                }
            }
            if !streams.gravity.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO gravitySample (deviceId, ts, x, y, z) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.gravity {
                    try stmt.execute(arguments: [deviceId, s.ts, s.x, s.y, s.z])
                    grav += db.changesCount
                }
            }
            // WHOOP5 step counter (#78). Persist-only, the count is not surfaced in the return tuple
            // (no consumer reads it; keeping the 8-field tuple avoids touching any caller/test).
            // `activityClass` (#316, v19 column) is the @63 activity-class enum (0=still/1=walk/2=run) the
            // decoder already carries on each StepSample; it was dropped here before v19. Bound as `s.activityClass`
            //, nil (the byte was 0xFF/invalid/absent) stores SQL NULL, so an absent class stays absent.
            if !streams.steps.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO stepSample (deviceId, ts, counter, activityClass) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.steps {
                    try stmt.execute(arguments: [deviceId, s.ts, s.counter, s.activityClass])
                }
            }
            // Band sleep_state (#175). Persist-only, same as steps — the strap's OWN @81 high-nibble state
            // (0 wake/1 still/2 asleep/3 up), decoded and streamed but dropped at storage until now. Keyed by
            // (deviceId, ts); ON CONFLICT DO NOTHING keeps the first-seen state for a second so a re-sync is
            // idempotent. The raw 0-3 code is stored verbatim — a strap that never reports it inserts nothing.
            if !streams.sleepState.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO sleepStateSample (deviceId, ts, state) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.sleepState {
                    try stmt.execute(arguments: [deviceId, s.ts, s.state])
                }
            }
            // PPG-derived HR from the v26 optical buffer (#156). Persist-only, same as steps, the count
            // is not added to the 8-field return tuple (the Backfiller call site reads that tuple by name;
            // extending it would ripple), so it is inserted without being counted. ON CONFLICT DO NOTHING
            // keeps the FIRST estimate for a second; the measured hrSample is never touched here.
            if !streams.ppgHr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO ppgHrSample (deviceId, ts, bpm, conf) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.ppgHr {
                    try stmt.execute(arguments: [deviceId, s.ts, s.bpm, s.conf])
                }
            }
            return (hr, rr, ev, bat, spo2, skin, resp, grav)
        }
    }

    // MARK: - Raw sensor CSV export (diagnostic)

    /// Long-format CSV column order. One stream's columns are filled per row; the rest stay blank.
    private static let rawCSVHeader =
        "unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter," +
        "ppg_bpm,ppg_conf,spo2_red,spo2_ir,skintemp_raw,resp_raw,band_sleep_state,event_kind,event_payload"

    /// One assembled CSV line: the 16 columns AFTER the `unix_s,iso_utc` prefix, joined with commas.
    /// `cols[0]` is the `stream` name; `cols[1...15]` are the per-stream value slots, only the ones
    /// that belong to this row's stream are non-empty.
    private struct RawCSVRow {
        let ts: Int
        var cols: [String]
        init(ts: Int) { self.ts = ts; self.cols = Array(repeating: "", count: 16) }
    }

    /// Export the decoded per-sample sensor streams NOOP already stores to ONE combined long-format CSV
    /// (header + one row per sample, all streams interleaved and sorted by ts ascending). On-device,
    /// plain text, no BLE hex, a diagnostic so power users / external devs can prototype sleep/activity/
    /// VBT algorithms on real data without a BLE stream (#308/#276/#322).
    ///
    /// `since` is a unix-seconds floor (caller passes now-24h); rows with `ts >= since` for `deviceId`
    /// are included. Writes to a temp file and returns its URL (caller hands it to the share/save flow).
    public func exportRawCSV(deviceId: String, since: TimeInterval) async throws -> URL {
        let floor = Int(since)
        let rows: [RawCSVRow] = try syncRead { db in
            var out: [RawCSVRow] = []

            // hr: stream=hr → hr_bpm (col 3).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, bpm FROM hrSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "hr"
                row.cols[1] = WhoopStore.intStr(r["bpm"])
                out.append(row)
            }
            // rr: stream=rr → rr_ms (col 4).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, rrMs FROM rrInterval WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "rr"
                row.cols[2] = WhoopStore.intStr(r["rrMs"])
                out.append(row)
            }
            // gravity: stream=gravity → grav_x/y/z (cols 5–7).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, x, y, z FROM gravitySample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "gravity"
                row.cols[3] = WhoopStore.dblStr(r["x"])
                row.cols[4] = WhoopStore.dblStr(r["y"])
                row.cols[5] = WhoopStore.dblStr(r["z"])
                out.append(row)
            }
            // steps: stream=steps → step_counter (col 8).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, counter FROM stepSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "steps"
                row.cols[6] = WhoopStore.intStr(r["counter"])
                out.append(row)
            }
            // ppghr: stream=ppghr → ppg_bpm/ppg_conf (cols 9–10).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, bpm, conf FROM ppgHrSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "ppghr"
                row.cols[7] = WhoopStore.dblStr(r["bpm"])
                row.cols[8] = WhoopStore.dblStr(r["conf"])
                out.append(row)
            }
            // spo2: stream=spo2 → spo2_red/spo2_ir (cols 11–12).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, red, ir FROM spo2Sample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "spo2"
                row.cols[9] = WhoopStore.intStr(r["red"])
                row.cols[10] = WhoopStore.intStr(r["ir"])
                out.append(row)
            }
            // skintemp: stream=skintemp → skintemp_raw (col 13).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, raw FROM skinTempSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "skintemp"
                row.cols[11] = WhoopStore.intStr(r["raw"])
                out.append(row)
            }
            // resp: stream=resp → resp_raw (col 14).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, raw FROM respSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "resp"
                row.cols[12] = WhoopStore.intStr(r["raw"])
                out.append(row)
            }
            // band sleep_state (#175): stream=band_sleep_state → band_sleep_state (col 15). The strap's
            // OWN @81 high-nibble state (0 wake/1 still/2 asleep/3 up), carried verbatim.
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, state FROM sleepStateSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "band_sleep_state"
                row.cols[13] = WhoopStore.intStr(r["state"])
                out.append(row)
            }
            // event: stream=event → event_kind/event_payload (cols 16–17). Payload is free-form JSON,
            // so it always goes through the CSV-quote escaper (commas/quotes/newlines).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, kind, payloadJSON FROM event WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "event"
                row.cols[14] = WhoopStore.csvField(r["kind"] ?? "")
                row.cols[15] = WhoopStore.csvField(r["payloadJSON"] ?? "")
                out.append(row)
            }

            // Stable sort by ts ascending. `sorted` is not guaranteed stable, but ties only occur across
            // different streams at the same second, any interleaving of those is acceptable here.
            out.sort { $0.ts < $1.ts }
            return out
        }

        // Stream the rows straight to disk through a FileHandle, flushing in ~64 KB chunks, instead of
        // building the whole CSV as one in-memory String: a busy 24 h export otherwise held tens of MB
        // twice, the assembled String plus its UTF-8 Data copy that `write(to:)` makes, and could OOM
        // (#406, parity with the Android exporter's streaming fix).
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.formatOptions = [.withInternetDateTime]

        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-raw-sensors-\(stamp).csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data((WhoopStore.rawCSVHeader + "\n").utf8))
        var buf = String()
        buf.reserveCapacity(72 * 1024)
        for row in rows {
            let isoStr = iso.string(from: Date(timeIntervalSince1970: TimeInterval(row.ts)))
            buf += "\(row.ts),\(isoStr),"
            buf += row.cols.joined(separator: ",")
            buf += "\n"
            if buf.utf8.count >= 64 * 1024 {
                try handle.write(contentsOf: Data(buf.utf8))
                buf.removeAll(keepingCapacity: true)
            }
        }
        if !buf.isEmpty { try handle.write(contentsOf: Data(buf.utf8)) }
        return url
    }

    /// Format an Int-valued GRDB column (blank for NULL) without the "Optional(...)" wrapper text.
    private static func intStr(_ v: Int?) -> String { v.map(String.init) ?? "" }

    /// Format a Double-valued GRDB column (blank for NULL). Plain decimal, `String(Double)` is
    /// round-trippable and locale-independent, which the comma-delimited CSV needs.
    private static func dblStr(_ v: Double?) -> String { v.map { String($0) } ?? "" }

    /// RFC-4180 CSV field: wrap in double quotes and double any embedded quote ONLY when the value
    /// contains a comma, quote, or newline. Used for the free-form event columns.
    private static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Test helpers

    public func storageStats_rowCountsForTest() async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        // Bind each count to its own `let` before assembling the tuple. Returning the whole tuple of
        // inline `try Int.fetchOne(...) ?? 0` expressions made Swift's type-checker time out on some
        // toolchains/machines (reported by a contributor building locally); splitting it is
        // behaviour-identical and trivial to type-check.
        try syncRead { db in
            let hr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0
            let rr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0
            let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
            let battery = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0
            let spo2 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spo2Sample") ?? 0
            let skinTemp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skinTempSample") ?? 0
            let resp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM respSample") ?? 0
            let gravity = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gravitySample") ?? 0
            return (hr, rr, events, battery, spo2, skinTemp, resp, gravity)
        }
    }

    public func stepCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stepSample") ?? 0 }
    }

    /// The strap's OWN banked band sleep_state samples (#175) in `[from, to]` for one device, ascending by
    /// ts. Each `(ts, state)` is the raw @81 high-nibble code (0 wake/1 still/2 asleep/3 up) carried
    /// verbatim off the offload stream. Empty when the strap never reported it (a WHOOP 4.0, or a not-yet-
    /// offloaded window). Feeds the Deep Timeline band-state track and the per-session grid the H7 guard reads.
    public func sleepStateSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [SleepStateSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, state FROM sleepStateSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { SleepStateSample(ts: $0["ts"], state: $0["state"]) }
        }
    }

    public func sleepStateCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sleepStateSample") ?? 0 }
    }

    public func ppgHrCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppgHrSample") ?? 0 }
    }

    public func deviceRowForTest(id: String) async throws -> (mac: String?, name: String?)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT mac, name FROM device WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return (row["mac"], row["name"])
        }
    }
}
