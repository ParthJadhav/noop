package com.noop.data

import androidx.room.withTransaction

/**
 * Device-registry façade over [WhoopDao] + [WhoopDatabase] — the Android port of the Swift
 * `DeviceRegistryStore` (Packages/WhoopStore). Owns the device list, the single-active invariant, and
 * the day-ownership override table.
 *
 * Invariant I1 (at most one `active` device) is enforced in [setActive]: the demote+promote pair runs
 * inside one transaction, so a crash mid-swap can never leave two active rows (or none).
 *
 * The transaction boundary is injected as [transactor] (defaulting to Room's `db.withTransaction`) so
 * the registry's logic is exercisable on the plain JVM without a real Room database — mirroring how the
 * rest of the test suite stays Robolectric-free (see DeviceRegistryTest / MoodStoreTest).
 */
class DeviceRegistry(
    private val dao: DeviceRegistryDao,
    private val transactor: Transactor,
) {
    /** A single-transaction boundary. Production wraps Room's `withTransaction`; tests pass through.
     *  Not a `fun interface` — a SAM method may not be generic — so implementors use the object form. */
    interface Transactor {
        suspend fun <R> run(block: suspend () -> R): R
    }

    /** Production constructor: wraps the DAO + Room transaction over [db]. */
    constructor(db: WhoopDatabase) : this(
        dao = db.whoopDao(),
        transactor = object : Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = db.withTransaction { block() }
        },
    )

    /** All paired devices, oldest first. */
    suspend fun all(): List<PairedDeviceRow> = dao.pairedDevices()

    /** The single active device id, or null if none. */
    suspend fun activeDeviceId(): String? = dao.activeDeviceId()

    /** Add (or update) a device. */
    suspend fun add(row: PairedDeviceRow) = dao.upsertPairedDevice(row)

    /**
     * Make [id] the single active device. The demote-old + promote-new pair is ONE transaction so the
     * "exactly one active" invariant (I1) holds even across a crash mid-swap — mirrors the Swift
     * store's single write transaction.
     */
    suspend fun setActive(id: String, now: Long = System.currentTimeMillis() / 1000) {
        transactor.run {
            dao.demoteActive()
            dao.promote(id, now)
        }
    }

    /** Archive a device — keeps its row and samples (invariant I4). */
    suspend fun archive(id: String) = dao.archiveDevice(id)

    /** Set the owner override for a day (insert-or-replace). */
    suspend fun setDayOwner(day: String, deviceId: String, locked: Boolean) =
        dao.setDayOwner(DayOwnershipRow(day = day, deviceId = deviceId, locked = locked))

    /** The owner override for a day, or null if none. */
    suspend fun dayOwner(day: String): DayOwnershipRow? = dao.dayOwner(day)
}
