package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the additive v15 -> v16 Room migration (the `liveSession` table, Live Sessions), the Android twin of
 * the Swift WhoopStore v22 migration. No Robolectric here, so the migration SQL is exposed as an internal
 * constant ([WhoopDatabase.LIVE_SESSION_MIGRATION_SQL]) and pinned to Room's generated shape for
 * [LiveSessionRow]: nullable `endTs`/`chargeAtStart`, the rest NOT NULL, composite PRIMARY KEY (deviceId,
 * startTs) in declaration order. See docs/superpowers/specs/2026-07-04-live-sessions-design.md.
 */
class LiveSessionMigrationTest {

    @Test
    fun migration_isAdditive_onlyCreateTable() {
        val sql = WhoopDatabase.LIVE_SESSION_MIGRATION_SQL
        assertEquals("one CREATE TABLE statement", 1, sql.size)
        for (s in sql) {
            val up = s.trimStart().uppercase()
            assertTrue("only CREATE TABLE allowed, got: $s", up.startsWith("CREATE TABLE"))
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "ALTER ")) {
                assertTrue("additive migration must not contain '$banned': $s", !up.contains(banned))
            }
        }
    }

    @Test
    fun migration_createsExactTable() {
        assertEquals(
            listOf(
                "CREATE TABLE IF NOT EXISTS `liveSession` (`deviceId` TEXT NOT NULL, " +
                    "`startTs` INTEGER NOT NULL, `endTs` INTEGER, `chargeAtStart` REAL, " +
                    "`floorBpm` REAL NOT NULL, `ceilingBpm` REAL NOT NULL, `inBandSec` REAL NOT NULL, " +
                    "`belowSec` REAL NOT NULL, `aboveSec` REAL NOT NULL, `pushCount` INTEGER NOT NULL, " +
                    "`easeCount` INTEGER NOT NULL, `hrSource` TEXT NOT NULL, " +
                    "PRIMARY KEY(`deviceId`, `startTs`))",
            ),
            WhoopDatabase.LIVE_SESSION_MIGRATION_SQL,
        )
    }

    @Test
    fun migration_versionPair_is15to16() {
        assertEquals(15, WhoopDatabase.MIGRATION_15_16.startVersion)
        assertEquals(16, WhoopDatabase.MIGRATION_15_16.endVersion)
    }

    @Test
    fun liveSessionRow_shape_matches_swift_twin() {
        val row = LiveSessionRow(
            deviceId = "my-whoop", startTs = 1000L, endTs = 3400L, chargeAtStart = 41.0,
            floorBpm = 128.0, ceilingBpm = 148.0, inBandSec = 1800.0, belowSec = 300.0, aboveSec = 120.0,
            pushCount = 2, easeCount = 1, hrSource = "whoop",
        )
        assertEquals("my-whoop", row.deviceId)
        assertEquals(3400L, row.endTs)
        assertEquals(41.0, row.chargeAtStart!!, 0.0001)
        assertEquals(1800.0, row.inBandSec, 0.0001)
        // In-progress session leaves endTs / chargeAtStart null.
        val open = LiveSessionRow("my-whoop", 5000L, null, null, 120.0, 150.0, 0.0, 0.0, 0.0, 0, 0, "strap")
        assertEquals(null, open.endTs)
        assertEquals(null, open.chargeAtStart)
    }
}
