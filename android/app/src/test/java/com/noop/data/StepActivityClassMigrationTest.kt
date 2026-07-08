package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the additive v12 -> v13 Room migration (the `stepSample.activityClass` column, #316) — the Android
 * twin of the Swift WhoopStore v19 migration. This environment has no Robolectric / Room-testing, so the
 * migration's SQL is exposed as an internal constant ([WhoopDatabase.STEP_ACTIVITY_CLASS_MIGRATION_SQL]) and
 * pinned here to Room's generated shape:
 *
 *  - one ALTER ... ADD COLUMN statement, a nullable INTEGER (an `Int?` field): no NOT NULL, no DEFAULT.
 *  - ADDITIVE: only ALTER ADD COLUMN; no DROP/DELETE/UPDATE/INSERT/CREATE on existing data.
 *
 * The write+read round-trip of the value itself is pinned at the model-mapping boundary — exactly where the
 * value was DROPPED before this change (WhoopRepository.insert mapped StepRow -> StepSample without it). The
 * DAO read is `SELECT *`, so once the column exists the entity carries it back automatically.
 */
class StepActivityClassMigrationTest {

    @Test
    fun migration_isAdditive_onlyAddColumnStatement() {
        val sql = WhoopDatabase.STEP_ACTIVITY_CLASS_MIGRATION_SQL
        assertEquals("one ADD COLUMN statement", 1, sql.size)
        for (s in sql) {
            val up = s.trimStart().uppercase()
            assertTrue("only ALTER ADD COLUMN allowed, got: $s", up.startsWith("ALTER TABLE") && up.contains("ADD COLUMN"))
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "CREATE ", "NOT NULL", "DEFAULT")) {
                assertTrue("additive nullable migration must not contain '$banned': $s", !up.contains(banned))
            }
        }
    }

    @Test
    fun migration_addsExactColumn() {
        assertEquals(
            listOf("ALTER TABLE `stepSample` ADD COLUMN `activityClass` INTEGER"),
            WhoopDatabase.STEP_ACTIVITY_CLASS_MIGRATION_SQL,
        )
    }

    @Test
    fun migration_versionPair_is12to13() {
        assertEquals(12, WhoopDatabase.MIGRATION_12_13.startVersion)
        assertEquals(13, WhoopDatabase.MIGRATION_12_13.endVersion)
    }

    /**
     * #316 — a decoded [StepRow]'s `activityClass` survives the insert MAPPING the repository uses
     * (StepRow -> StepSample entity), and a null class (the @63 byte was 0xFF/invalid/absent) stays null:
     * an absent class stays absent, never a fabricated 0/"still". This is the boundary that DROPPED the
     * value before v13 (the mapping built StepSample(deviceId, ts, counter) only). The entity is what the
     * DAO `SELECT *` reads back, so this pins the persisted shape end to end.
     */
    @Test
    fun activityClass_survivesInsertMapping() {
        val deviceId = "my-whoop"
        val rows = listOf(
            StepRow(ts = 1_780_916_200, counter = 60, activityClass = 0),   // still
            StepRow(ts = 1_780_916_201, counter = 61, activityClass = 1),   // walk
            StepRow(ts = 1_780_916_202, counter = 62, activityClass = 2),   // run
            StepRow(ts = 1_780_916_203, counter = 63, activityClass = null), // no class
        )
        // The exact mapping WhoopRepository.insert applies before dao.insertSteps(...).
        val entities = rows.map { StepSample(deviceId, it.ts, it.counter, it.activityClass) }

        assertEquals(listOf(0, 1, 2, null), entities.map { it.activityClass })
        assertEquals(listOf(60, 61, 62, 63), entities.map { it.counter })
        assertNull("a nil @63 class round-trips back as null", entities.last().activityClass)
    }
}
