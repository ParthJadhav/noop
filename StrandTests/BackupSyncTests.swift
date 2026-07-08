import XCTest
@testable import Strand

/// Pure snapshot-naming / selection / prune logic behind Backup & Sync (the folder destination).
/// Mirror of the Android `BackupSyncTest` - same filename scheme, same newest-first selection, same
/// keep-N prune semantics - so the two platforms stay behaviourally identical (must-fix #6).
final class BackupSyncTests: XCTestCase {

    func testNameRoundTripsToUtcSecond() {
        let ms = 1_782_000_000_000 // a whole-second instant (UTC)
        let name = BackupSync.snapshotName(ms)
        XCTAssertTrue(name.hasPrefix("noop-backup-"))
        XCTAssertTrue(name.hasSuffix(".noopbak"))
        XCTAssertEqual(BackupSync.snapshotTimeMs(name), ms) // second-resolution round-trip
    }

    func testIsSnapshotRejectsNonBackups() {
        XCTAssertTrue(BackupSync.isSnapshot(BackupSync.snapshotName(1_782_000_000_000)))
        XCTAssertFalse(BackupSync.isSnapshot("photo.jpg"))
        XCTAssertFalse(BackupSync.isSnapshot("noop-backup-notadate.noopbak"))
        XCTAssertFalse(BackupSync.isSnapshot("noop-backup-20260627-123456.zip"))
        XCTAssertNil(BackupSync.snapshotTimeMs("random.txt"))
    }

    func testLatestPicksNewest() {
        let older = BackupSync.snapshotName(1_782_000_000_000)
        let newer = BackupSync.snapshotName(1_782_000_600_000) // +10 min
        XCTAssertEqual(BackupSync.latestSnapshot([older, "junk.txt", newer]), newer)
        XCTAssertNil(BackupSync.latestSnapshot(["a.txt", "b.bin"]))
    }

    func testSnapshotsNewestFirstSortsAndDropsNonSnapshots() {
        let a = BackupSync.snapshotName(1_782_000_000_000)
        let b = BackupSync.snapshotName(1_782_000_060_000)
        let c = BackupSync.snapshotName(1_782_000_120_000)
        let sorted = BackupSync.snapshotsNewestFirst([a, "x.txt", c, b])
        XCTAssertEqual(sorted, [c, b, a])
    }

    func testPruneKeepsNewestN() {
        let names = (0..<5).map { BackupSync.snapshotName(1_782_000_000_000 + $0 * 60_000) }
        let pruned = BackupSync.snapshotsToPrune(names + ["keepme.txt"], keep: 2)
        XCTAssertEqual(pruned.count, 3)
        XCTAssertTrue(pruned.contains(names[0]))    // oldest pruned
        XCTAssertFalse(pruned.contains(names[4]))   // newest kept
        XCTAssertFalse(pruned.contains("keepme.txt")) // non-snapshots never pruned
    }

    func testPruneNoOpWithinBudget() {
        XCTAssertTrue(BackupSync.snapshotsToPrune([BackupSync.snapshotName(1_782_000_000_000)], keep: 10).isEmpty)
    }

    // MARK: - Restore listing accepts ANY .noopbak, including date-only manual names (#852)

    func testIsBackupFileAcceptsAnyNoopbakExtension() {
        XCTAssertTrue(BackupSync.isBackupFile("noop-backup-2026-06-30.noopbak"))       // date-only manual name
        XCTAssertTrue(BackupSync.isBackupFile(BackupSync.snapshotName(1_782_000_000_000)))
        XCTAssertTrue(BackupSync.isBackupFile("whatever-i-named-it.noopbak"))          // arbitrary name
        XCTAssertTrue(BackupSync.isBackupFile("BACKUP.NOOPBAK"))                        // case-insensitive
        XCTAssertFalse(BackupSync.isBackupFile("noop-backup-20260630-120000.zip"))     // wrong extension
        XCTAssertFalse(BackupSync.isBackupFile("photo.jpg"))
    }

    func testRestorablesIncludeDateOnlyNamesAndOrderNewestFirst() {
        // The reporter's exact folder: a date-only manual export plus a canonical timestamped one (#852).
        let canonical = BackupSync.snapshotName(1_782_000_600_000)   // has an embedded stamp
        let dateOnly = "noop-backup-2026-06-30.noopbak"             // no parseable stamp
        // dateOnly's file date is NEWER than the canonical's embedded stamp, so it must sort first.
        let fileDates = [dateOnly: 1_782_000_600_000 + 60_000, canonical: 0, "notes.txt": 999]
        let out = BackupSync.restorablesNewestFirst(
            [canonical, dateOnly, "notes.txt"],
            fileDateMs: { fileDates[$0] ?? 0 }
        )
        // Both .noopbak files present, .txt dropped, newest-first by resolved time.
        XCTAssertEqual(out.map(\.name), [dateOnly, canonical])
        // Canonical keeps its embedded stamp; date-only takes the supplied file date.
        XCTAssertEqual(out.first(where: { $0.name == canonical })?.timeMs, 1_782_000_600_000)
        XCTAssertEqual(out.first(where: { $0.name == dateOnly })?.timeMs, 1_782_000_600_000 + 60_000)
    }

    func testRestorablesDoNotWidenPrune() {
        // A hand-named .noopbak is restorable but must NEVER become a prune candidate.
        let dateOnly = "noop-backup-2026-06-30.noopbak"
        let canon = (0..<12).map { BackupSync.snapshotName(1_782_000_000_000 + $0 * 60_000) }
        let pruned = BackupSync.snapshotsToPrune(canon + [dateOnly], keep: 10)
        XCTAssertFalse(pruned.contains(dateOnly))   // hand-named backup never auto-deleted
    }

    func testRestorablesTieBreakOnNameWhenTimesEqual() {
        // Two hand-named files that resolve to the SAME time (identical file-modification date) must order
        // deterministically by name asc - the same tie-break Kotlin uses - so equal-time rows list
        // identically on both platforms and there's no order flap between listings.
        let z = "zeta.noopbak"
        let a = "alpha.noopbak"
        let sameMs = 1_782_000_000_000
        let out = BackupSync.restorablesNewestFirst([z, a]) { _ in sameMs }
        XCTAssertEqual(out.map(\.name), [a, z])
    }
}
