import Foundation
import GRDB

/// SQLite-level integrity verification for the backup/restore pipeline (#1014 defence-in-depth).
///
/// The `.noopbak` import already gates on the 16-byte SQLite magic and on the migrator's
/// bookkeeping table (`grdb_migrations` / `room_master_table`), but BOTH of those live in the first
/// pages of the file: a backup that was truncated mid-upload, torn by a dying SD card, or clipped by
/// a cloud-sync client still passes them — and then "restores" into a store that silently shows no
/// data, which is exactly the #1014 report (our #1000 settings code was exonerated; the file itself
/// was the suspect). The missing armour is SQLite's own verdict: `PRAGMA quick_check` walks the page
/// structure and catches malformed pages, truncation ("size is N pages but the header says M"), and
/// bad cell layouts. `quick_check` (not `integrity_check`) deliberately skips index-content
/// verification so it stays proportionate on a 100 MB+ library while still refusing every
/// structurally damaged file.
///
/// Lives in the package — not the app's `DataBackup` — for the same reason `BackupSettings` does:
/// the verdict is pure SQLite + string logic, so it is unit-testable headlessly
/// (`swift test --filter DatabaseIntegrityTests`) against real damaged files. The Android
/// `DataBackup.quickCheckVerdict` mirrors `verdict(fromRows:)` byte-for-byte on the same golden
/// vectors, so both platforms agree on what "healthy" means.
public enum DatabaseIntegrity {

    /// Run `PRAGMA quick_check(1)` over a READ-ONLY connection on the database at `path`.
    ///
    /// Returns `nil` when the file is healthy, otherwise SQLite's first complaint (or the open/query
    /// error) as a short human-readable string for the caller's honest failure message. Read-only by
    /// construction: the probed file — a staged backup, or the live store just after a swap — is
    /// never mutated, and a read-only connection can sit beside the app's open GRDB pool (WAL allows
    /// concurrent readers; a checkpointed backup file has no WAL at all).
    public static func quickCheckFailure(atPath path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return "no database file at that path"
        }
        var config = Configuration()
        config.readonly = true
        do {
            let dbQueue = try DatabaseQueue(path: path, configuration: config)
            let rows = try dbQueue.read { db in
                try String.fetchAll(db, sql: "PRAGMA quick_check(1)")
            }
            return verdict(fromRows: rows)
        } catch {
            // Open or query failed outright (SQLITE_NOTADB on a garbage file, malformed header, …).
            // That IS the verdict: the file is not a usable database.
            return error.localizedDescription
        }
    }

    /// Pure classification of the rows `PRAGMA quick_check` returned: `nil` = healthy (the single
    /// canonical `"ok"` row), otherwise the first complaint row verbatim — never a fabricated
    /// summary. An EMPTY result set is treated as a failure too: quick_check always answers, so
    /// silence means the query itself was swallowed and the file must not be trusted.
    /// Mirrored by Android's `DataBackup.quickCheckVerdict` on the same golden vectors.
    public static func verdict(fromRows rows: [String]) -> String? {
        if rows.count == 1, rows[0].lowercased() == "ok" { return nil }
        return rows.first { $0.lowercased() != "ok" } ?? "quick_check returned no verdict"
    }
}
