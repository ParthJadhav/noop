package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [DeviceRegistry] contract tests — mirror the Swift DeviceRegistryStoreTests in
 * Packages/WhoopStore. The project ships NO Robolectric (junit + kotlinx-coroutines-test only — see
 * app/build.gradle.kts and MoodStoreTest), so rather than build a real Room DB these run the REAL
 * [DeviceRegistry] over an in-memory [FakeRegistryDao] that reproduces the DAO's SQL semantics exactly:
 *   - pairedDevices()  ORDER BY addedAt ASC
 *   - activeDeviceId() the single row WHERE status='active', LIMIT 1
 *   - upsertPairedDevice() / setDayOwner()  INSERT OR REPLACE by PK
 *   - demoteActive() + promote()  the single-active swap (run together via the pass-through transactor)
 * The fake is seeded with `my-whoop` active, exactly as MIGRATION_7_8 seeds the real DB.
 */
class DeviceRegistryTest {

    /** In-memory stand-in for [DeviceRegistryDao]. The (deviceId, status) bookkeeping reproduces the
     *  pairedDevice table; [day] map reproduces dayOwnership. No transaction isolation is modelled —
     *  the registry's [DeviceRegistry.setActive] is what couples demote+promote, and the test's
     *  transactor runs the block straight through, exactly as Room's withTransaction would commit it. */
    private class FakeRegistryDao : DeviceRegistryDao {
        val devices = LinkedHashMap<String, PairedDeviceRow>() // insertion order ≈ addedAt order
        val owners = LinkedHashMap<String, DayOwnershipRow>()

        override suspend fun pairedDevices(): List<PairedDeviceRow> =
            devices.values.sortedBy { it.addedAt }

        override suspend fun activeDeviceId(): String? =
            devices.values.firstOrNull { it.status == DeviceStatus.active.name }?.id

        override suspend fun upsertPairedDevice(row: PairedDeviceRow) {
            devices[row.id] = row // INSERT OR REPLACE by id PK
        }

        override suspend fun demoteActive() {
            for ((id, row) in devices) {
                if (row.status == DeviceStatus.active.name) {
                    devices[id] = row.copy(status = DeviceStatus.paired.name)
                }
            }
        }

        override suspend fun promote(id: String, now: Long) {
            devices[id]?.let { devices[id] = it.copy(status = DeviceStatus.active.name, lastSeenAt = now) }
        }

        override suspend fun archiveDevice(id: String) {
            devices[id]?.let { devices[id] = it.copy(status = DeviceStatus.archived.name) }
        }

        override suspend fun setDayOwner(row: DayOwnershipRow) {
            owners[row.day] = row // INSERT OR REPLACE by day PK
        }

        override suspend fun dayOwner(day: String): DayOwnershipRow? = owners[day]
    }

    /** Registry over the fake DAO with a pass-through transactor (Room's withTransaction stand-in). */
    private fun registryWith(dao: FakeRegistryDao) =
        DeviceRegistry(
            dao,
            object : DeviceRegistry.Transactor {
                override suspend fun <R> run(block: suspend () -> R): R = block()
            },
        )

    /** Seed the fake exactly as MIGRATION_7_8 does: `my-whoop`, brand/model WHOOP, liveBLE, active. */
    private fun seededDao(): FakeRegistryDao = FakeRegistryDao().apply {
        devices["my-whoop"] = PairedDeviceRow(
            id = "my-whoop", brand = "WHOOP", model = "WHOOP", nickname = null,
            sourceKind = SourceKind.liveBLE.name,
            capabilities = "hr,hrv,spo2,skinTemp,sleep,strainLoad",
            status = DeviceStatus.active.name, addedAt = 100, lastSeenAt = 100,
        )
    }

    @Test
    fun seededWhoopIsActive() = runBlocking {
        val reg = registryWith(seededDao())
        val all = reg.all()
        assertEquals(1, all.size)
        assertEquals("my-whoop", all.first().id)
        assertEquals("my-whoop", reg.activeDeviceId())
    }

    @Test
    fun setActiveDemotesPreviousAndKeepsExactlyOneActive() = runBlocking {
        val dao = seededDao()
        val reg = registryWith(dao)
        reg.add(
            PairedDeviceRow(
                id = "polar-1", brand = "Polar", model = "H10", nickname = null,
                sourceKind = SourceKind.liveBLE.name, capabilities = "hr,hrv",
                status = DeviceStatus.paired.name, addedAt = 200, lastSeenAt = 200,
            ),
        )

        reg.setActive("polar-1", now = 999)

        assertEquals("polar-1", reg.activeDeviceId())
        val byId = reg.all().associate { it.id to it.status }
        assertEquals(DeviceStatus.active.name, byId["polar-1"])
        assertEquals(DeviceStatus.paired.name, byId["my-whoop"]) // the previously-active device demoted
        // Invariant I1: exactly one active row.
        assertEquals(1, reg.all().count { it.status == DeviceStatus.active.name })
        assertEquals(999L, reg.all().first { it.id == "polar-1" }.lastSeenAt) // promote stamped lastSeenAt
    }

    @Test
    fun archiveKeepsRowAndClearsActive() = runBlocking {
        val reg = registryWith(seededDao())
        reg.archive("my-whoop")
        // I4: the row is kept (not deleted), just archived.
        assertEquals(1, reg.all().size)
        assertEquals(DeviceStatus.archived.name, reg.all().first().status)
        assertNull(reg.activeDeviceId())
    }

    @Test
    fun dayOwnerUpsertAndRead() = runBlocking {
        val reg = registryWith(seededDao())
        assertNull(reg.dayOwner("2000-01-01"))

        reg.setDayOwner("2026-06-15", "my-whoop", locked = true)
        assertNotNull(reg.dayOwner("2026-06-15"))
        assertEquals("my-whoop", reg.dayOwner("2026-06-15")!!.deviceId)
        assertEquals(true, reg.dayOwner("2026-06-15")!!.locked)

        // Upsert: re-writing the same day replaces the owner + locked flag (no duplicate row).
        reg.setDayOwner("2026-06-15", "polar-1", locked = false)
        assertEquals("polar-1", reg.dayOwner("2026-06-15")!!.deviceId)
        assertEquals(false, reg.dayOwner("2026-06-15")!!.locked)
    }
}
