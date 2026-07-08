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
    /**
     * The strap's stable BLE peripheral identifier — on Android the [android.bluetooth.BluetoothDevice]
     * MAC address (also exposed as [com.noop.ble.WhoopBleClient.lastDeviceAddress]). Added by the v8 → v9
     * additive migration (the Android twin of the Swift `peripheralId` column). Lets the BLE client pin a
     * connect to ONE specific strap (multi-WHOOP) and lets a freshly-paired device be looked up by its
     * address. Nullable, no SQL DEFAULT (matches Room's generated column for a `String?` field); the
     * seeded "my-whoop" row keeps it NULL until the strap is (re)paired.
     */
    val peripheralId: String? = null,
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

/** How a device's data reaches the store. Stored as the enum name (Swift `SourceKind` rawValue).
 *  [ftms] = a live FTMS gym machine (treadmill / indoor bike / rower / cross-trainer).
 *  [huami] = an EXPERIMENTAL Huami-family live HR source (Amazfit / Zepp incl. Helio, Xiaomi Mi Band):
 *  standard 0x180D when exposed, else the documented Huami custom HR characteristic, else an honest
 *  "needs pairing" message. (Garmin uses [liveBLE] — its live HR is the standard broadcast-HR path.)
 *  [oura] = an EXPERIMENTAL Oura ring live BLE source. Owns its OWN scanner/GATT (never touches the
 *  WHOOP client); decodes the ring's own raw signals + open HRV/sleep-phase tags and runs NOOP's own
 *  scoring, and surfaces an honest "needs pairing" state when the install key is absent (never Oura's
 *  encrypted readiness/sleep scores). Carried on string rawValue "oura"; no DB migration (the column is
 *  free-text and existing rows never carry it).
 *  Additive: existing rows never carry [ftms]/[huami]/[oura]; only the respective wizard paths write them. */
enum class SourceKind { liveBLE, historyBLE, cloudImport, fileImport, ftms, huami, oura }

/** A canonical metric a source can provide — drives capability-aware UI + the day-owner resolver.
 *  Stored as the enum name (Swift `Metric` rawValue) inside the comma-joined `capabilities` string. */
enum class Metric { hr, hrv, spo2, skinTemp, steps, sleep, strainLoad }
