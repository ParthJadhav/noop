package com.noop.data

import androidx.room.Entity
import androidx.room.PrimaryKey

/*
 * Device-registry schema — the Android port of the Swift foundation in
 * Packages/WhoopStore (PairedDevice.swift + DeviceRegistryStore.swift) and the Database.swift v15
 * `pairedDevice` / `dayOwnership` migration. Added to Room as the v7 → v8 additive migration.
 *
 * `id` is the SAME string used as `deviceId` in every sample table's (deviceId, ts) key, so a
 * device's raw samples are already isolated by id — no per-row source column is needed. The existing
 * WHOOP keeps id "my-whoop" (zero sample-row migration); it is seeded `active` by MIGRATION_7_8.
 */

/**
 * A device the user has paired. PK = [id] (== `deviceId` in the sample tables). [capabilities] is the
 * comma-joined set of [Metric] rawValues, byte-for-byte matching the Swift store's encoding so a
 * cross-platform backup round-trips. Exactly one row is `active` at a time (invariant I1, enforced in
 * [DeviceRegistry.setActive]).
 */
@Entity(tableName = "pairedDevice")
data class PairedDeviceRow(
    @PrimaryKey
    val id: String,
    val brand: String,
    val model: String,
    val nickname: String?,
    val sourceKind: String,
    val capabilities: String, // comma-joined Metric rawValues, e.g. "hr,hrv,sleep"
    val status: String,
    val addedAt: Long, // unix seconds
    val lastSeenAt: Long, // unix seconds
)

/**
 * Override of which device owns a given local day's displayed/scored metrics (invariant I2: a day's
 * scores are never blended across sources). PK = [day] ("YYYY-MM-DD"). [locked] = true means an
 * explicit decision (import-overlap resolution / user choice) that the resolver must honour over its
 * priority default. Port of the Swift `dayOwnership` table.
 */
@Entity(tableName = "dayOwnership")
data class DayOwnershipRow(
    @PrimaryKey
    val day: String,
    val deviceId: String,
    val locked: Boolean = false,
)

/** Lifecycle of a paired device. Stored as the lowercase enum name (Swift `DeviceStatus` rawValue). */
enum class DeviceStatus { active, paired, archived }

/** How a device's data reaches the store. Stored as the enum name (Swift `SourceKind` rawValue). */
enum class SourceKind { liveBLE, historyBLE, cloudImport, fileImport }

/** A canonical metric a source can provide — drives capability-aware UI + the day-owner resolver.
 *  Stored as the enum name (Swift `Metric` rawValue) inside the comma-joined `capabilities` string. */
enum class Metric { hr, hrv, spo2, skinTemp, steps, sleep, strainLoad }
