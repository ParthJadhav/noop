package com.noop.data

import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

/**
 * The device-registry slice of the DAO (pairedDevice / dayOwnership, schema v8) — the Android port of
 * the Swift `DeviceRegistryStore` reads/writes. Split into its own interface (which [WhoopDao] extends)
 * so [DeviceRegistry] depends on a narrow, easily-faked surface and can be unit-tested on the plain JVM
 * without Room/Robolectric (see DeviceRegistryTest). Room flattens these inherited annotated methods
 * into the concrete @Dao at compile time, so they generate identically to being declared on WhoopDao.
 */
interface DeviceRegistryDao {

    /** All paired devices, oldest first (Swift `all()` ORDER BY addedAt ASC). */
    @Query("SELECT * FROM pairedDevice ORDER BY addedAt ASC")
    suspend fun pairedDevices(): List<PairedDeviceRow>

    /** The single `active` device id, or null if none (e.g. after archiving the only device). */
    @Query("SELECT id FROM pairedDevice WHERE status = 'active' LIMIT 1")
    suspend fun activeDeviceId(): String?

    /** Insert-or-replace a device by its id PK (Swift `add`'s ON CONFLICT(id) DO UPDATE upsert). */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertPairedDevice(row: PairedDeviceRow)

    /** Demote whatever device is currently active to `paired`. Half of the single-active swap
     *  (invariant I1); MUST run in the same transaction as [promote] — see [DeviceRegistry.setActive]. */
    @Query("UPDATE pairedDevice SET status = 'paired' WHERE status = 'active'")
    suspend fun demoteActive()

    /** Promote one device to `active` and stamp its lastSeenAt. Other half of the I1 swap. */
    @Query("UPDATE pairedDevice SET status = 'active', lastSeenAt = :now WHERE id = :id")
    suspend fun promote(id: String, now: Long)

    /** Archive a device (keeps the row + its samples — invariant I4). */
    @Query("UPDATE pairedDevice SET status = 'archived' WHERE id = :id")
    suspend fun archiveDevice(id: String)

    /** Set the owner override for a day (insert-or-replace by the day PK). */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun setDayOwner(row: DayOwnershipRow)

    /** The owner override for a day, or null if none has been set. */
    @Query("SELECT * FROM dayOwnership WHERE day = :day")
    suspend fun dayOwner(day: String): DayOwnershipRow?
}
