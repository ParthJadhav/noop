package com.noop.analytics

import com.noop.ble.WhoopModel
import com.noop.data.DeviceRegistry
import com.noop.data.DeviceStatus
import com.noop.data.SourceKind
import com.noop.protocol.DeviceFamily

/**
 * [IntelligenceEngine.DayOwnerSource] backed by the [DeviceRegistry] (Phase 1B-4). Supplies the engine
 * with the per-day owner-resolution inputs so a day is scored from exactly ONE device (invariant I2),
 * without giving the pure-JVM engine a Room dependency.
 *
 * Priorities mirror the Swift IntelligenceEngine.resolveDayOwner exactly:
 *   0 = the active strap, 1 = other live (BLE/historyBLE) straps, 2 = imports (cloud/file). Lower wins.
 * Archived devices are excluded. With only the seeded active 'my-whoop' row paired (the default and
 * every single-WHOOP install), the sole candidate is priority 0, so the engine resolves to "my-whoop"
 * for every day and the reads stay byte-identical to the single-source path.
 */
class RegistryDayOwnerSource(private val registry: DeviceRegistry) : IntelligenceEngine.DayOwnerSource {

    override suspend fun candidatePriorities(): List<Pair<String, Int>> {
        val activeId = registry.activeDeviceId()
        return registry.all()
            .filter { it.status != DeviceStatus.archived.name }
            .map { d ->
                val isImport = d.sourceKind == SourceKind.cloudImport.name ||
                    d.sourceKind == SourceKind.fileImport.name
                val priority = when {
                    d.id == activeId -> 0
                    isImport -> 2
                    else -> 1
                }
                d.id to priority
            }
    }

    // Any dayOwnership override wins outright, regardless of its `locked` flag — matching the Swift
    // `(try? registry.dayOwner(day))?.deviceId` read in IntelligenceEngine.resolveDayOwner, which uses
    // the stored owner as an authoritative override (the `locked` flag gates the UI, not the read).
    override suspend fun lockedOwner(day: String): String? = registry.dayOwner(day)?.deviceId

    // CAPTURE-B: the registry's active strap id, for the universal dayOwner diagnostic's writeActiveId.
    // This is the SAME id the live read path resolves to (BLEManager/AppModel's activeDeviceId), so the
    // universal line can prove the read owner and the write target are the same device (or surface it
    // when they diverge, the #814/#799 spine symptom).
    override suspend fun activeWriteId(): String? = registry.activeDeviceId()

    // #938: resolve the strap family that wrote [deviceId]'s rows from its registry model. A device whose
    // model is "WHOOP 4.0" maps to WHOOP4 (raw-ADC skin-temp scale); everything else — a 5/MG, a non-WHOOP
    // import whose skin temp is already °C, or an id absent from the registry — falls back to WHOOP5 (the
    // prior /100 behaviour). Mirrors the Swift IntelligenceEngine.skinTempFamily(forOwner:devices:).
    override suspend fun skinTempFamily(deviceId: String): DeviceFamily {
        val model = registry.all().firstOrNull { it.id == deviceId }?.model
        return if (WhoopModel.entries.firstOrNull { it.displayName == model } == WhoopModel.WHOOP4)
            DeviceFamily.WHOOP4 else DeviceFamily.WHOOP5
    }
}
