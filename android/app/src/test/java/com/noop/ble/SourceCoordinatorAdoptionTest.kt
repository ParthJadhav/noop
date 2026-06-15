package com.noop.ble

import com.noop.data.DayOwnershipRow
import com.noop.data.DeviceRegistry
import com.noop.data.DeviceRegistryDao
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [SourceCoordinator.connectedPeripheralChanged] identity-adoption + GUARD tests — the Kotlin twin of the
 * macOS `SourceCoordinator.connectedPeripheralChanged(to:)` behaviour (Strand/BLE/SourceCoordinator.swift
 * 213-231). The critical assertion is the different-strap guard: a strap whose address differs from the
 * active WHOOP row's already-adopted `peripheralId` must NEVER overwrite it (that would mis-map another
 * physical strap's samples onto this device's row).
 *
 * Harness mirrors DeviceRegistryTest: the project ships NO mocking framework and NO Robolectric (junit +
 * kotlinx-coroutines-test only — see app/build.gradle.kts), so this runs the REAL [DeviceRegistry] over an
 * in-memory [FakeRegistryDao] (the DAO's SQL semantics reproduced by hand). The coordinator's Android-only
 * deps ([context]/[repository]) are passed null — only [switchToStrap] touches them, and the adoption path
 * never reaches it. [Dispatchers.Unconfined] makes `scope.launch { … }` run eagerly inside `runBlocking`,
 * so the registry write is observable synchronously after the call.
 */
class SourceCoordinatorAdoptionTest {

    /** In-memory [DeviceRegistryDao] (same reproduction as DeviceRegistryTest, trimmed to what's used). */
    private class FakeRegistryDao : DeviceRegistryDao {
        val devices = LinkedHashMap<String, PairedDeviceRow>()
        val owners = LinkedHashMap<String, DayOwnershipRow>()

        override suspend fun pairedDevices(): List<PairedDeviceRow> = devices.values.sortedBy { it.addedAt }
        override suspend fun activeDeviceId(): String? =
            devices.values.firstOrNull { it.status == DeviceStatus.active.name }?.id
        override suspend fun upsertPairedDevice(row: PairedDeviceRow) { devices[row.id] = row }
        override suspend fun demoteActive() {
            for ((id, row) in devices) if (row.status == DeviceStatus.active.name) {
                devices[id] = row.copy(status = DeviceStatus.paired.name)
            }
        }
        override suspend fun promote(id: String, now: Long) {
            devices[id]?.let { devices[id] = it.copy(status = DeviceStatus.active.name, lastSeenAt = now) }
        }
        override suspend fun archiveDevice(id: String) {
            devices[id]?.let { devices[id] = it.copy(status = DeviceStatus.archived.name) }
        }
        override suspend fun renameDevice(id: String, nickname: String?) {
            devices[id]?.let { devices[id] = it.copy(nickname = nickname) }
        }
        override suspend fun setPeripheralId(id: String, peripheralId: String?) {
            devices[id]?.let { devices[id] = it.copy(peripheralId = peripheralId) }
        }
        override suspend fun deviceForPeripheralId(peripheralId: String): PairedDeviceRow? =
            devices.values.firstOrNull { it.peripheralId == peripheralId }
        override suspend fun setDayOwner(row: DayOwnershipRow) { owners[row.day] = row }
        override suspend fun dayOwner(day: String): DayOwnershipRow? = owners[day]

        // Sample-table deletes are unmodelled here (validated by the Room-backed integration).
        override suspend fun deleteHrFor(deviceId: String) {}
        override suspend fun deleteRrFor(deviceId: String) {}
        override suspend fun deleteSpo2For(deviceId: String) {}
        override suspend fun deleteSkinTempFor(deviceId: String) {}
        override suspend fun deleteRespFor(deviceId: String) {}
        override suspend fun deleteGravityFor(deviceId: String) {}
        override suspend fun deleteStepsFor(deviceId: String) {}
        override suspend fun deletePpgHrFor(deviceId: String) {}
        override suspend fun deleteEventsFor(deviceId: String) {}
        override suspend fun deleteBatteryFor(deviceId: String) {}
        override suspend fun deleteDailyMetricsFor(deviceId: String) {}
        override suspend fun deleteSleepSessionsFor(deviceId: String) {}
        override suspend fun deleteJournalFor(deviceId: String) {}
        override suspend fun deleteWorkoutsFor(deviceId: String) {}
        override suspend fun deleteAppleDailyFor(deviceId: String) {}
        override suspend fun deleteMetricSeriesFor(deviceId: String) {}
        override suspend fun deleteDayOwnershipFor(deviceId: String) {
            owners.entries.removeIf { it.value.deviceId == deviceId }
        }
    }

    private fun registryWith(dao: FakeRegistryDao) = DeviceRegistry(
        dao,
        object : DeviceRegistry.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = block()
        },
    )

    /** A WHOOP row seeded active, with the given [peripheralId] (null = not yet adopted). */
    private fun whoopRow(id: String, peripheralId: String?) = PairedDeviceRow(
        id = id, brand = "WHOOP", model = "WHOOP", nickname = null,
        sourceKind = SourceKind.liveBLE.name, capabilities = "hr",
        status = DeviceStatus.active.name, addedAt = 100, lastSeenAt = 100,
        peripheralId = peripheralId,
    )

    private fun coordinatorOver(dao: FakeRegistryDao, log: (String) -> Unit = {}): SourceCoordinator =
        SourceCoordinator(
            context = null,                       // adoption path never reaches switchToStrap
            registry = registryWith(dao),
            repository = null,                    // same
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined), // launch runs eagerly inside runBlocking
            log = log,
        )

    @Test
    fun nullPeripheralIdRowAdoptsConnectedAddress() = runBlocking {
        val dao = FakeRegistryDao().apply { devices["my-whoop"] = whoopRow("my-whoop", peripheralId = null) }
        val coordinator = coordinatorOver(dao)

        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")

        assertEquals("AA:BB:CC:DD:EE:01", dao.devices["my-whoop"]!!.peripheralId)
    }

    @Test
    fun matchingAddressIsANoOp() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        var logged: String? = null
        val coordinator = coordinatorOver(dao) { logged = it }

        // Same strap reconnecting (case-insensitive match) — nothing written, nothing logged.
        coordinator.connectedPeripheralChanged("aa:bb:cc:dd:ee:01")

        assertEquals("AA:BB:CC:DD:EE:01", dao.devices["my-whoop"]!!.peripheralId)
        assertNull("matching address must not log a different-strap notice", logged)
    }

    @Test
    fun differentStrapDoesNotOverwriteAndLogs() = runBlocking {
        // The GUARD: the active WHOOP row already adopted ...:01; a DIFFERENT strap ...:02 connects.
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        var logged: String? = null
        val coordinator = coordinatorOver(dao) { logged = it }

        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:02")

        // Stored identity is UNCHANGED — the other strap's address never lands on this row.
        assertEquals("AA:BB:CC:DD:EE:01", dao.devices["my-whoop"]!!.peripheralId)
        // And the mismatch is logged with the exact macOS wording.
        assertEquals(
            "Multi-WHOOP: active device my-whoop is registered to strap AA:BB:CC:DD:EE:01 but " +
                "AA:BB:CC:DD:EE:02 connected — not overwriting.",
            logged,
        )
    }

    @Test
    fun nullAddressIsIgnored() = runBlocking {
        val dao = FakeRegistryDao().apply { devices["my-whoop"] = whoopRow("my-whoop", peripheralId = null) }
        val coordinator = coordinatorOver(dao)

        coordinator.connectedPeripheralChanged(null) // a disconnect republish

        assertNull(dao.devices["my-whoop"]!!.peripheralId) // nothing adopted
    }

    @Test
    fun nonWhoopActiveDeviceIsIgnored() = runBlocking {
        // A generic strap is the active device — this WHOOP-side connection isn't ours; do not touch it.
        val dao = FakeRegistryDao().apply {
            devices["polar-1"] = PairedDeviceRow(
                id = "polar-1", brand = "Polar", model = "H10", nickname = null,
                sourceKind = SourceKind.liveBLE.name, capabilities = "hr,hrv",
                status = DeviceStatus.active.name, addedAt = 200, lastSeenAt = 200,
                peripheralId = null,
            )
        }
        val coordinator = coordinatorOver(dao)

        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")

        assertNull("a generic-strap active row must not adopt a WHOOP connection's address",
            dao.devices["polar-1"]!!.peripheralId)
        assertTrue(dao.devices.size == 1)
    }
}
