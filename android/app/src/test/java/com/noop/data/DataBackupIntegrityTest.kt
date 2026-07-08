package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #1014 defence-in-depth: golden vectors for the pure quick_check verdict, mirrored byte-for-byte
 * by the Apple side's `DatabaseIntegrityTests.testVerdictGoldenVectors` (WhoopStore package), so
 * both platforms agree on what "healthy" means. The `PRAGMA quick_check(1)` execution itself needs
 * a real Android SQLite (android.database.sqlite is a throwing stub on the plain JVM) and lives
 * behind [DataBackup]'s private read-only wrapper; the classification pinned here is the part that
 * decides accept vs refuse for the import/export integrity gates, so it is what gets the
 * cross-platform vectors.
 */
class DataBackupIntegrityTest {

    @Test fun healthySingleOkRowPasses() {
        // SQLite emits the canonical row lowercase; accept any case (matches the Apple side).
        assertNull(DataBackup.quickCheckVerdict(listOf("ok")))
        assertNull(DataBackup.quickCheckVerdict(listOf("OK")))
    }

    @Test fun complaintRowComesBackVerbatim() {
        // Never a fabricated summary - the caller surfaces SQLite's own words.
        assertEquals(
            "*** in database main ***\nPage 5 is never used",
            DataBackup.quickCheckVerdict(listOf("*** in database main ***\nPage 5 is never used")),
        )
        assertEquals(
            "row 12 missing from index sleepIdx",
            DataBackup.quickCheckVerdict(listOf("row 12 missing from index sleepIdx")),
        )
    }

    @Test fun silenceIsNotHealth() {
        // quick_check always answers; an empty result means the query was swallowed - refuse.
        assertEquals("quick_check returned no verdict", DataBackup.quickCheckVerdict(emptyList()))
    }

    @Test fun multipleRowsCanNeverMeanHealthy() {
        assertEquals(
            "Page 9 is never used",
            DataBackup.quickCheckVerdict(listOf("ok", "Page 9 is never used")),
        )
    }
}
