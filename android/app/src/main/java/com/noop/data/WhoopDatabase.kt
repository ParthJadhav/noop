package com.noop.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * Local Room database, the Android port of the GRDB store in
 * Packages/WhoopStore (Database.swift schema). Holds phone-collected raw streams
 * AND the offline cache of server-computed derived metrics.
 *
 * The schema bundles every Swift migration (v1..v9) into a single fresh shape, since the
 * Android app starts from an empty store (no in-place migration from a prior Android version).
 * version 2 added the v8 journal/workout/appleDaily caches. **v3 (#78)** adds the stepSample table
 * + dailyMetric.steps/activeKcalEst via a REAL additive migration (MIGRATION_2_3), NOT a destructive
 * rebuild, so a user's already-offloaded raw streams survive (the strap trims acked history and won't
 * re-send it). The destructive fallback is deliberately GONE: with exportSchema=false there's no
 * build-time schema check, so a hand-written-SQL mismatch would otherwise SILENTLY wipe that history;
 * without the fallback Room throws loudly instead, and MigrationRoundTripTest guards the SQL in CI.
 */
@Database(
    entities = [
        DeviceRow::class,
        HrSample::class,
        RrInterval::class,
        EventRow::class,
        BatterySample::class,
        Spo2Sample::class,
        SkinTempSample::class,
        StepSample::class,
        SleepStateSampleEntity::class,
        RespSample::class,
        GravitySample::class,
        DailyMetric::class,
        SleepSession::class,
        MetricSeriesRow::class,
        JournalEntry::class,
        WorkoutRow::class,
        DismissedWorkout::class,
        DismissedSleep::class,
        AppleDaily::class,
        PpgHrSample::class,
        PairedDeviceRow::class,
        DayOwnershipRow::class,
        LabMarkerRow::class,
        LiveSessionRow::class,
    ],
    version = 16,
    exportSchema = false,
)
abstract class WhoopDatabase : RoomDatabase() {
    abstract fun whoopDao(): WhoopDao

    companion object {
        const val DB_NAME = "noop_whoop.db"

        @Volatile
        private var instance: WhoopDatabase? = null

        /** Process-wide singleton. Safe to call from any thread. */
        fun get(context: Context): WhoopDatabase =
            instance ?: synchronized(this) {
                instance ?: build(context.applicationContext).also { instance = it }
            }

        /**
         * Close and forget the singleton so all file handles on [DB_NAME] are released.
         * The next [get] call rebuilds against whatever file is on disk, used by
         * [DataBackup.importFrom] to swap the database file underneath the app.
         */
        fun close() {
            synchronized(this) {
                instance?.close()
                instance = null
            }
        }

        /**
         * v2 → v3: ADDITIVE ONLY, adds the stepSample table + dailyMetric.steps/activeKcalEst.
         * A real (non-destructive) migration so an existing user's already-offloaded raw streams are
         * PRESERVED (the strap trims acked history chunks and will not re-send them, so a destructive
         * rebuild would lose that history permanently). The SQL MUST match Room's generated schema
         * exactly, NOT NULL for `synced` (Kotlin default, no SQL DEFAULT), nullable INTEGER/REAL for
         * the two new dailyMetric columns. Guarded by MigrationRoundTripTest.
         */
        internal val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `stepSample` (`deviceId` TEXT NOT NULL, " +
                        "`ts` INTEGER NOT NULL, `counter` INTEGER NOT NULL, " +
                        "`synced` INTEGER NOT NULL, PRIMARY KEY(`deviceId`, `ts`))",
                )
                db.execSQL("ALTER TABLE `dailyMetric` ADD COLUMN `steps` INTEGER")
                db.execSQL("ALTER TABLE `dailyMetric` ADD COLUMN `activeKcalEst` REAL")
            }
        }

        /**
         * v3 -> v4: ADDITIVE, adds `workout.routePolyline` (nullable TEXT) for GPS routes. Nullable so
         * existing workouts migrate untouched; the SQL must match Room's generated schema for a `String?`
         * column exactly (TEXT, no NOT NULL, no default). Mirrors MIGRATION_2_3's additive form.
         */
        internal val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `workout` ADD COLUMN `routePolyline` TEXT")
            }
        }

        /**
         * v4 -> v5: ADDITIVE, adds the `dismissedWorkout` table (#107): a durable marker that keeps a
         * dismissed auto-detected bout hidden after the engine re-derives it. CREATE TABLE only (no
         * data touched), so existing workouts/history are untouched. The SQL MUST match Room's
         * generated schema for the [DismissedWorkout] entity exactly, all three PK columns NOT NULL,
         * composite PRIMARY KEY in declaration order. Guarded by MigrationRoundTripTest like the others.
         */
        internal val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `dismissedWorkout` (`deviceId` TEXT NOT NULL, " +
                        "`startTs` INTEGER NOT NULL, `endTs` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`deviceId`, `startTs`))",
                )
            }
        }

        /**
         * v5 -> v6: ADDITIVE, adds the `ppgHrSample` table (#156): HR derived from the WHOOP 5/MG
         * v26 optical PPG waveform (autocorrelation). CREATE TABLE only (no existing data touched), so
         * already-offloaded raw streams survive (the strap trims acked history and won't re-send it).
         * The SQL MUST match Room's generated schema for [PpgHrSample] exactly, every column NOT NULL
         * (Kotlin defaults, no SQL DEFAULT), `conf` is REAL, composite PRIMARY KEY (deviceId, ts) in
         * declaration order. Guarded by MigrationRoundTripTest like the others.
         */
        internal val MIGRATION_5_6 = object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `ppgHrSample` (`deviceId` TEXT NOT NULL, " +
                        "`ts` INTEGER NOT NULL, `bpm` INTEGER NOT NULL, `conf` REAL NOT NULL, " +
                        "`synced` INTEGER NOT NULL, PRIMARY KEY(`deviceId`, `ts`))",
                )
            }
        }

        /**
         * v6 -> v7: ADDITIVE, adds `sleepSession.userEdited` + `sleepSession.startTsAdjusted` for
         * durable bed/wake editing (port of iOS PR #395, the GRDB v13 `userEdited` + v14
         * `startTsAdjusted` migrations). `userEdited` is a non-null Kotlin Boolean → Room stores it as
         * INTEGER NOT NULL DEFAULT 0; `startTsAdjusted` is a nullable Long → INTEGER (no NOT NULL).
         * Both are ALTER ... ADD COLUMN only (no data touched), so existing rows are untouched and read
         * back as userEdited=false / startTsAdjusted=null, exactly the additive, nullable-safe form of
         * MIGRATION_2_3. The SQL MUST match Room's generated schema for the new columns; like the
         * others this is the no-destructive-fallback path so a mismatch throws loudly instead of
         * silently wiping non-resendable strap history.
         */
        internal val MIGRATION_6_7 = object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `sleepSession` ADD COLUMN `userEdited` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `sleepSession` ADD COLUMN `startTsAdjusted` INTEGER")
            }
        }

        /**
         * v7 -> v8: ADDITIVE, adds the device registry (`pairedDevice` + `dayOwnership`), the Android
         * port of the Swift Database.swift v15 migration. CREATE TABLE only (no existing data touched),
         * so already-offloaded raw streams survive (the strap trims acked history and won't re-send it).
         *
         * The SQL MUST match Room's generated schema for [PairedDeviceRow]/[DayOwnershipRow] exactly:
         *  - pairedDevice: `nickname` is the only nullable column (TEXT, no NOT NULL); every other is
         *    NOT NULL with no SQL DEFAULT (Kotlin construction defaults don't emit a schema default).
         *  - dayOwnership: `locked` is a non-null Kotlin Boolean with a *constructor* default of false,          *    Room stores it as INTEGER NOT NULL with NO SQL DEFAULT (the Kotlin default never reaches the
         *    schema), so the migration must NOT add `DEFAULT 0` or MigrationRoundTripTest would flag a
         *    schema mismatch.
         *
         * Seeds the existing WHOOP with its unchanged id "my-whoop" (zero sample-row migration), brand/
         * model "WHOOP", sourceKind 'liveBLE', the full capability set, status 'active', and addedAt/
         * lastSeenAt = now (seconds). `INSERT OR IGNORE` so a re-run / backup-restore is a no-op. The
         * capabilities string + column order are byte-for-byte the Swift seed so a backup round-trips.
         * Like the others this is the no-destructive-fallback path: a mismatch throws loudly rather than
         * silently wiping non-resendable strap history; CI's MigrationRoundTripTest guards the SQL.
         */
        internal val MIGRATION_7_8 = object : Migration(7, 8) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `pairedDevice` (`id` TEXT NOT NULL, " +
                        "`brand` TEXT NOT NULL, `model` TEXT NOT NULL, `nickname` TEXT, " +
                        "`sourceKind` TEXT NOT NULL, `capabilities` TEXT NOT NULL, " +
                        "`status` TEXT NOT NULL, `addedAt` INTEGER NOT NULL, " +
                        "`lastSeenAt` INTEGER NOT NULL, PRIMARY KEY(`id`))",
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `dayOwnership` (`day` TEXT NOT NULL, " +
                        "`deviceId` TEXT NOT NULL, `locked` INTEGER NOT NULL, PRIMARY KEY(`day`))",
                )
                val now = System.currentTimeMillis() / 1000
                db.execSQL(
                    "INSERT OR IGNORE INTO `pairedDevice` " +
                        "(`id`, `brand`, `model`, `nickname`, `sourceKind`, `capabilities`, " +
                        "`status`, `addedAt`, `lastSeenAt`) VALUES " +
                        "('my-whoop', 'WHOOP', 'WHOOP', NULL, 'liveBLE', " +
                        "'hr,hrv,spo2,skinTemp,sleep,strainLoad', 'active', $now, $now)",
                )
            }
        }

        /**
         * v8 -> v9: ADDITIVE, adds `pairedDevice.peripheralId` (nullable TEXT), the strap's stable BLE
         * peripheral identifier (the Android twin of the Swift Database.swift `peripheralId` migration).
         * On Android this is the [android.bluetooth.BluetoothDevice] MAC address; it lets the BLE client
         * pin a connect to ONE specific strap (multi-WHOOP) and lets a freshly-paired device be looked up
         * by its address.
         *
         * ALTER ... ADD COLUMN only (no data touched), so existing rows are untouched and read back with
         * `peripheralId = NULL`, including the seeded "my-whoop" row (WHOOP has no stored MAC until it is
         * (re)paired, fine). The SQL MUST match Room's generated column for a `String?` field exactly:
         * TEXT, no NOT NULL, no SQL DEFAULT (a Kotlin construction default never reaches the schema), the
         * additive, nullable-safe form of MIGRATION_3_4. Like the others this is the no-destructive-
         * fallback path: a mismatch throws loudly rather than silently wiping non-resendable strap history;
         * CI's MigrationRoundTripTest guards the SQL.
         */
        internal val MIGRATION_8_9 = object : Migration(8, 9) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `pairedDevice` ADD COLUMN `peripheralId` TEXT")
            }
        }

        /**
         * v9 -> v10: ADDITIVE, adds the `dismissedSleep` tombstone table (#33): a durable marker that
         * keeps a user-DELETED computed sleep night from regenerating on the next recompute. CREATE TABLE
         * only (no data touched), so already-offloaded raw streams survive. The SQL MUST match Room's
         * generated schema for [DismissedSleep] exactly, all three columns NOT NULL, composite PRIMARY
         * KEY (deviceId, startTs) in declaration order. Mirrors MIGRATION_4_5 (the dismissedWorkout table).
         */
        internal val MIGRATION_9_10 = object : Migration(9, 10) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `dismissedSleep` (`deviceId` TEXT NOT NULL, " +
                        "`startTs` INTEGER NOT NULL, `endTs` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`deviceId`, `startTs`))",
                )
            }
        }

        /**
         * v10 -> v11: ADDITIVE, adds the `labMarker` table (Health Records "Lab Book" pillar), the
         * Android port of the Swift Database.swift v17 migration. One row per dated reading the USER
         * entered themselves; the daily `metricSeries` projection under source `lab-book` is how the
         * book talks to the rest of the app. CREATE TABLE + indexes only (no existing data touched),
         * so already-offloaded raw streams survive.
         *
         * NON-CLINICAL: the table holds ONLY user-entered values + an OPTIONAL user-entered
         * `referenceText` (their own report's range). No reference-range tables, no normality verdict.
         *
         * The SQL MUST match Room's generated schema for [LabMarkerRow] exactly:
         *  - PRIMARY KEY is the single TEXT `id`.
         *  - `value`, `valueText`, `note`, `referenceText` are the only nullable columns (Kotlin `?`,
         *    no NOT NULL); every other column is NOT NULL with NO SQL DEFAULT (a Kotlin construction
         *    default never reaches the schema).
         *  - Three indexes, byte-for-byte the Swift v17 indexes: a UNIQUE natural-key index plus two
         *    non-unique lookup indexes, with the exact names Room derives from the @Index annotations.
         * Like the others this is the no-destructive-fallback path: a mismatch throws loudly rather
         * than silently wiping non-resendable strap history.
         *
         * The SQL is exposed as the [LAB_MARKER_MIGRATION_SQL] constants (below) so a plain-JVM unit
         * test ([com.noop.data.LabMarkerMigrationTest]) can pin this shape WITHOUT needing Robolectric
         * or a fake SupportSQLiteDatabase. Edit the constants and the migration changes in lockstep.
         */
        internal val LAB_MARKER_CREATE_SQL =
            "CREATE TABLE IF NOT EXISTS `labMarker` (`id` TEXT NOT NULL, " +
                "`deviceId` TEXT NOT NULL, `markerKey` TEXT NOT NULL, " +
                "`category` TEXT NOT NULL, `day` TEXT NOT NULL, `takenAt` INTEGER NOT NULL, " +
                "`value` REAL, `valueText` TEXT, `unit` TEXT NOT NULL, `source` TEXT NOT NULL, " +
                "`note` TEXT, `referenceText` TEXT, PRIMARY KEY(`id`))"

        internal val LAB_MARKER_INDEX_SQL = listOf(
            "CREATE UNIQUE INDEX IF NOT EXISTS `idx_labMarker_natural` " +
                "ON `labMarker` (`deviceId`, `markerKey`, `takenAt`, `source`)",
            "CREATE INDEX IF NOT EXISTS `idx_labMarker_device_marker_takenAt` " +
                "ON `labMarker` (`deviceId`, `markerKey`, `takenAt`)",
            "CREATE INDEX IF NOT EXISTS `idx_labMarker_device_category` " +
                "ON `labMarker` (`deviceId`, `category`)",
        )

        /** All statements the migration runs, in order, the table then its indexes. */
        internal val LAB_MARKER_MIGRATION_SQL: List<String> =
            listOf(LAB_MARKER_CREATE_SQL) + LAB_MARKER_INDEX_SQL

        internal val MIGRATION_10_11 = object : Migration(10, 11) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in LAB_MARKER_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v11 -> v12: ADDITIVE, adds `sleepSession.motionJSON` + `sleepSession.sleepStateJSON` (nullable
         * TEXT), the Android port of the Swift WhoopStore v18 migration. Per-epoch analytics banked beside
         * the existing `stagesJSON` on the same row: the SleepStager's per-epoch motion magnitudes (H8) and
         * the decoded v18 band sleep_state per epoch (H2 persist half).
         *
         * ALTER ... ADD COLUMN only (no data touched), so existing rows are untouched and read back with
         * both columns = NULL, exactly the additive, nullable-safe form of MIGRATION_3_4 (already-offloaded
         * raw streams survive; the strap trims acked history and won't re-send it). The SQL MUST match Room's
         * generated column for a `String?` field exactly: TEXT, no NOT NULL, no SQL DEFAULT (a Kotlin
         * construction default never reaches the schema). Like the others this is the no-destructive-fallback
         * path: a mismatch throws loudly rather than silently wiping non-resendable history.
         *
         * The SQL is exposed as [SLEEP_MOTION_STATE_MIGRATION_SQL] so a plain-JVM unit test
         * ([com.noop.data.SleepMotionStateMigrationTest]) can pin this shape without Robolectric.
         */
        internal val SLEEP_MOTION_STATE_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `sleepSession` ADD COLUMN `motionJSON` TEXT",
            "ALTER TABLE `sleepSession` ADD COLUMN `sleepStateJSON` TEXT",
        )

        internal val MIGRATION_11_12 = object : Migration(11, 12) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in SLEEP_MOTION_STATE_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v12 -> v13: ADDITIVE, adds `stepSample.activityClass` (nullable INTEGER), the Android port of the
         * Swift WhoopStore v19 migration. The @63 activity-class enum (0=still, 1=walk, 2=run; null when the
         * byte was 0xFF/invalid/absent) the decoder ALREADY carries on [StepRow] but which was DROPPED at the
         * insert boundary, the v2_3 `stepSample` held only ts/counter, so a classed sample could never be
         * persisted, read, or shown. (#316)
         *
         * ALTER ... ADD COLUMN only (no data touched), so existing rows are untouched and read back with
         * `activityClass = NULL`, an absent class stays absent, never a fabricated 0/"still". The SQL MUST
         * match Room's generated column for an `Int?` field exactly: INTEGER, no NOT NULL, no SQL DEFAULT (a
         * Kotlin construction default never reaches the schema), the additive, nullable-safe form of
         * MIGRATION_3_4. Already-offloaded raw streams survive (the strap trims acked history and won't
         * re-send it). Like the others this is the no-destructive-fallback path: a mismatch throws loudly
         * rather than silently wiping non-resendable history.
         *
         * The SQL is exposed as [STEP_ACTIVITY_CLASS_MIGRATION_SQL] so a plain-JVM unit test
         * ([com.noop.data.StepActivityClassMigrationTest]) can pin this shape without Robolectric.
         */
        internal val STEP_ACTIVITY_CLASS_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `stepSample` ADD COLUMN `activityClass` INTEGER",
        )

        internal val MIGRATION_12_13 = object : Migration(12, 13) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in STEP_ACTIVITY_CLASS_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v13 -> v14: ADDITIVE, adds `journal.numericValue` (#322 / task #53). A journal entry can carry a
         * numeric value (caffeine mg, alcohol units) alongside the yes/no answer. A numeric log writes
         * answeredYes=1 AND numericValue=v, so the EffectRanker with/without split keeps working unchanged;
         * the value is carried for dose-response.
         *
         * ALTER ... ADD COLUMN only (no data touched): existing rows read back `numericValue = NULL`
         * (a plain yes/no answer with no numeric reading), an absent value stays absent, never a fabricated
         * 0. The SQL MUST match Room's generated column for a `Double?` field exactly: REAL, no NOT NULL, no
         * SQL DEFAULT, the additive, nullable-safe form of MIGRATION_3_4. Twin of the Swift WhoopStore v20
         * migration. No destructive fallback (see the class doc): a mismatch throws loudly rather than
         * silently wiping non-resendable strap history.
         *
         * The SQL is exposed as [JOURNAL_NUMERIC_MIGRATION_SQL] so a plain-JVM unit test
         * ([com.noop.data.JournalNumericMigrationTest]) can pin this shape without Robolectric.
         */
        internal val JOURNAL_NUMERIC_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `journal` ADD COLUMN `numericValue` REAL",
        )

        internal val MIGRATION_13_14 = object : Migration(13, 14) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in JOURNAL_NUMERIC_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v14 -> v15: ADDITIVE, adds the `sleepStateSample` table (#175). The strap's OWN band sleep_state
         * (the @81 high nibble: 0 wake/1 still/2 asleep/3 up) was DECODED but DROPPED at stream extraction,
         * so the band-state chain (the H7 morning-stillness re-onset CONFIRM guard + a Deep Timeline track)
         * had no source and the per-session `sleepStateJSON` column was never fed. This new RAW per-sample
         * table, keyed by (deviceId, ts) like stepSample/ppgHrSample, idempotently upserts a second's band
         * state from the offload stream. `state` is the raw 0-3 code carried VERBATIM — never a fabricated
         * value; a strap that never reports it simply has no rows.
         *
         * CREATE TABLE only (no existing data touched), so already-offloaded raw streams survive (the strap
         * trims acked history and won't re-send it). The SQL MUST match Room's generated schema for
         * [SleepStateSampleEntity] exactly, every column NOT NULL (Kotlin, no SQL DEFAULT), composite PRIMARY
         * KEY (deviceId, ts) in declaration order. Twin of the Swift WhoopStore v21 migration. No destructive
         * fallback (see the class doc). Exposed as [SLEEP_STATE_SAMPLE_MIGRATION_SQL] so a plain-JVM unit test
         * can pin the shape without Robolectric.
         */
        internal val SLEEP_STATE_SAMPLE_MIGRATION_SQL: List<String> = listOf(
            "CREATE TABLE IF NOT EXISTS `sleepStateSample` (`deviceId` TEXT NOT NULL, " +
                "`ts` INTEGER NOT NULL, `state` INTEGER NOT NULL, PRIMARY KEY(`deviceId`, `ts`))",
        )

        internal val MIGRATION_14_15 = object : Migration(14, 15) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in SLEEP_STATE_SAMPLE_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v15 -> v16: ADDITIVE, adds the `liveSession` table (Live Sessions). One row per silent-guardian
         * coaching session, natural key (deviceId, startTs); `endTs` null while in progress. Twin of the Swift
         * WhoopStore v22 migration. CREATE TABLE only (no existing data touched). The SQL MUST match Room's
         * generated schema for [LiveSessionRow] exactly: nullable `endTs`/`chargeAtStart` (no NOT NULL), the
         * rest NOT NULL (Kotlin non-null, no SQL DEFAULT), composite PRIMARY KEY (deviceId, startTs) in
         * declaration order. No destructive fallback (see the class doc). Exposed as [LIVE_SESSION_MIGRATION_SQL]
         * so a plain-JVM unit test can pin the shape without Robolectric.
         * See docs/superpowers/specs/2026-07-04-live-sessions-design.md.
         */
        internal val LIVE_SESSION_MIGRATION_SQL: List<String> = listOf(
            "CREATE TABLE IF NOT EXISTS `liveSession` (`deviceId` TEXT NOT NULL, " +
                "`startTs` INTEGER NOT NULL, `endTs` INTEGER, `chargeAtStart` REAL, " +
                "`floorBpm` REAL NOT NULL, `ceilingBpm` REAL NOT NULL, `inBandSec` REAL NOT NULL, " +
                "`belowSec` REAL NOT NULL, `aboveSec` REAL NOT NULL, `pushCount` INTEGER NOT NULL, " +
                "`easeCount` INTEGER NOT NULL, `hrSource` TEXT NOT NULL, " +
                "PRIMARY KEY(`deviceId`, `startTs`))",
        )

        internal val MIGRATION_15_16 = object : Migration(15, 16) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in LIVE_SESSION_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        private fun build(appContext: Context): WhoopDatabase =
            Room.databaseBuilder(appContext, WhoopDatabase::class.java, DB_NAME)
                // #1014: replace ONLY the corruption handling of the default open-helper. The
                // platform default silently DELETES a corrupt database file (non-resendable strap
                // history gone without a trace); this factory logs + preserves the file instead.
                // Every migration/lifecycle callback is delegated to Room unchanged.
                .openHelperFactory(CorruptionPreservingOpenHelperFactory())
                // Real additive migration, NO destructive fallback (see the class doc): with
                // exportSchema=false a silent rebuild would lose already-acked, non-resendable strap
                // history on any schema mismatch. Room throws loudly instead; CI guards the SQL.
                .addMigrations(
                    MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5,
                    MIGRATION_5_6, MIGRATION_6_7, MIGRATION_7_8, MIGRATION_8_9, MIGRATION_9_10,
                    MIGRATION_10_11, MIGRATION_11_12, MIGRATION_12_13, MIGRATION_13_14,
                    MIGRATION_14_15, MIGRATION_15_16,
                )
                .build()
    }
}
