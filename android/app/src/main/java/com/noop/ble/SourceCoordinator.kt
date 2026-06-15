package com.noop.ble

import android.content.Context
import android.util.Log
import com.noop.data.DeviceRegistry
import com.noop.data.PairedDeviceRow
import com.noop.data.StreamBatch
import com.noop.data.WhoopRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Runs exactly ONE device's live BLE at a time, driven by [DeviceRegistry]'s active device id.
 *
 * Faithful Kotlin twin of Strand/BLE/SourceCoordinator.swift.
 *
 * WHOOP-FIRST, ZERO REGRESSION
 * ----------------------------
 * This coordinator is a deliberate NO-OP whenever the active device is the WHOOP (id "my-whoop", any
 * `brand == "WHOOP"` row, OR an unknown id). That is the default state and EVERY state where no generic
 * strap is paired: WHOOP is active, the coordinator does nothing, and the existing WHOOP flow
 * ([WhoopBleClient.connect] via [AppViewModel.connect]) runs exactly as it does today. It only ever
 * *acts* when the active device is a NON-WHOOP generic HR strap:
 *
 *   • switching TO a generic strap → [stopWhoop] (WHOOP's existing disconnect), then start the isolated
 *     [StandardHrSource] for that strap's deviceId.
 *   • switching BACK to WHOOP     → stop the [StandardHrSource], then [startWhoop] (WHOOP's existing scan
 *     entry) — but only if we had actually been on a strap, so a plain launch with WHOOP active does NOT
 *     re-trigger a redundant WHOOP scan.
 *
 * It never imports or references [WhoopBleClient] internals: the WHOOP start/stop are injected closures
 * from the composition root, so the two BLE flows stay fully decoupled (mirrors [StandardHrSource]'s
 * isolation). Live HR from a strap is pushed through [liveSink]; the app wires that to the SAME live
 * state the UI observes (e.g. `ble::publishExternalLiveHr`).
 *
 * On Android the registry exposes the active id as a one-shot suspend read (not a published flow like
 * Swift's `@Published activeDeviceId`), so the app calls [onActiveDeviceChanged] after any registry
 * mutation that can change the active device (the Devices screen's setActive — the next task), and
 * [start] reconciles once against the current active id at launch (a no-op for a single-WHOOP install).
 */
class SourceCoordinator(
    /** Android [Context] for the strap source's own scanner/GATT. Non-null in production (set at the
     *  composition root); nullable ONLY so the registry-driven paths (e.g. identity adoption) are
     *  exercisable on the plain JVM without Android — required at the single strap-path use site. */
    private val context: Context?,
    private val registry: DeviceRegistry,
    /** The store the strap source persists into. Non-null in production; nullable for the same JVM-test
     *  reason as [context] — required at the single strap-path use site, untouched by the WHOOP/adoption
     *  paths. */
    private val repository: WhoopRepository?,
    /** Push a strap's live HR/R-R into whatever the UI observes (e.g. `ble::publishExternalLiveHr`). */
    private val liveSink: (hr: Int, rr: List<Int>) -> Unit,
    /** Re-trigger WHOOP's EXISTING scan/connect entry point (e.g. `AppViewModel.connect`). */
    private val startWhoop: () -> Unit,
    /** Pause WHOOP via its EXISTING teardown (e.g. `AppViewModel.disconnect` → `ble.disconnect`). */
    private val stopWhoop: () -> Unit,
    /**
     * Pin the WHOOP connection to ONE strap by its persisted `peripheralId` (the MAC address), or null to
     * clear the pin back to "connect to the first WHOOP found". Wraps [WhoopBleClient.preferredAddress].
     * Called only on a WHOOP transition; nil on the legacy "my-whoop" path (unchanged). Default no-op keeps
     * the existing `SourceCoordinator(...)` call sites compiling unchanged. (MW-2/MW-3)
     */
    private val setWhoopPreferredAddress: (String?) -> Unit = {},
    /**
     * Re-point which device id live WHOOP samples store under. Wraps [WhoopBleClient.setActiveDeviceId].
     * Called ONLY when the active WHOOP is NOT the seeded "my-whoop" — the single-WHOOP path never invokes
     * it, so the id stays "my-whoop". Default no-op keeps existing call sites compiling unchanged. (MW-3)
     */
    private val setWhoopActiveDeviceId: (String) -> Unit = {},
    /** Background scope for the suspend registry reads + persist. SupervisorJob keeps one failure from
     *  cancelling the others; IO keeps DB work off the main thread. */
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    /** Diagnostic sink for the multi-WHOOP identity-adoption "different strap connected" notice — the
     *  Android analogue of Swift's `live.append(log:)`. Defaults to logcat; tests inject a capturing
     *  closure to assert the wording. Inert on the single-WHOOP path (the message only fires on a
     *  registered-but-mismatched strap). */
    private val log: (String) -> Unit = { Log.i("SourceCoordinator", it) },
) {

    /** The lazily-created generic-strap source. null until the first switch to a strap; reused after. */
    private var standardSource: StandardHrSource? = null
    /** The deviceId [standardSource] is currently running for (so we don't churn on the same id). */
    private var activeStrapId: String? = null
    /** The WHOOP registry id we last pointed the connection at, so a WHOOP→WHOOP switch is detected and a
     *  repeat activation of the SAME WHOOP is a no-op. null until the first WHOOP activation. (MW-3) */
    private var activeWhoopId: String? = null
    /** True once we've transitioned onto a generic strap. While false (the default / WHOOP-active state)
     *  switching to WHOOP is a pure no-op — we never issue a redundant WHOOP (re)scan. */
    private var onStrap = false
    /** The last active id we reconciled, so a repeated [onActiveDeviceChanged] for the same id is a no-op
     *  (mirrors Swift's `removeDuplicates()` on the published active id). */
    private var lastSeenId: String? = null

    /**
     * Reconcile once against the CURRENT active id (launch). For a single-WHOOP install this resolves to
     * the WHOOP and is a pure no-op, so the existing WHOOP startup is untouched.
     */
    fun start() {
        scope.launch {
            val id = registry.activeDeviceId() ?: WhoopBleClient.DEFAULT_DEVICE_ID
            reconcile(id)
        }
    }

    /**
     * Called by the app after a registry mutation that can change the active device (Devices-screen
     * setActive). Resolves the device for [id] and reconciles which live source runs. Idempotent: a
     * repeated call for the same id is dropped (the `removeDuplicates()` equivalent).
     */
    fun onActiveDeviceChanged(id: String) {
        scope.launch { reconcile(id) }
    }

    /**
     * The BLE engine connected to a WHOOP strap at [address] (null on disconnect). Persist that stable
     * identity onto the CURRENTLY ACTIVE device when it's a WHOOP and hasn't adopted one yet — so the
     * legacy "my-whoop" learns its strap's address on first connect, and a freshly-paired WHOOP confirms
     * its identity. Faithful twin of macOS `SourceCoordinator.connectedPeripheralChanged(to:)` (the sink
     * fed by `BLEManager.connectedPeripheralUUID`), INCLUDING the different-strap guard.
     *
     * Guards (so this never corrupts the registry):
     *   • null address (a disconnect/never-connected republish) → ignore.
     *   • the active device is NOT a WHOOP (a generic strap is active) → ignore; this connection isn't ours.
     *   • the active WHOOP already has a DIFFERENT non-null peripheralId → a different strap connected; LOG
     *     it and do NOT clobber the stored identity (would mis-map another strap's samples onto this row).
     *   • it already matches → nothing to write.
     */
    fun connectedPeripheralChanged(address: String?) {
        if (address == null) return
        scope.launch {
            val activeId = registry.activeDeviceId() ?: return@launch
            val devices = registry.all()
            val row = devices.firstOrNull { it.id == activeId }
            if (!isWhoop(activeId, devices) || row == null) return@launch

            val existing = row.peripheralId
            when {
                existing == null ->
                    // First connect for this WHOOP row → adopt the strap's stable identity (its address).
                    registry.setPeripheralId(activeId, address)
                existing.equals(address, ignoreCase = true) -> {
                    // Already adopted this exact strap → nothing to do.
                }
                else ->
                    // A DIFFERENT strap connected under this WHOOP row. Never silently overwrite — that would
                    // mis-map another physical strap's samples onto this device. Log and leave the stored id.
                    log(
                        "Multi-WHOOP: active device $activeId is registered to strap $existing but " +
                            "$address connected — not overwriting.",
                    )
            }
        }
    }

    private suspend fun reconcile(id: String) {
        if (id == lastSeenId) return
        lastSeenId = id
        val devices = registry.all()
        if (isWhoop(id, devices)) switchToWhoop(id, devices) else switchToStrap(id)
    }

    /**
     * Active device is a WHOOP ([id]). Three churn-guarded sub-cases, mirroring macOS
     * `SourceCoordinator.switchToWhoop`:
     *   • Already streaming this exact WHOOP with no strap in between → pure no-op (the dormant default;
     *     the single-WHOOP launch lands here and touches nothing but the initial preferred-address).
     *   • Coming back from a generic strap → stop that source, point WHOOP at this id, resume its scan.
     *   • A DIFFERENT WHOOP → drop the current link, re-point (preferred address + deviceId), reconnect.
     */
    private fun switchToWhoop(id: String, devices: List<PairedDeviceRow>) {
        // Already streaming this exact WHOOP with no strap in between → nothing to do.
        if (!onStrap && activeWhoopId == id) return

        val peripheralId = devices.firstOrNull { it.id == id }?.peripheralId

        when {
            onStrap -> {
                // Coming back from a generic strap: tear that source down first, then resume WHOOP.
                standardSource?.stop()
                activeStrapId = null
                onStrap = false
                pointWhoop(id, peripheralId)
                startWhoop()
            }
            activeWhoopId == null -> {
                // First WHOOP activation of the session (the normal launch path). Set the targeting so the
                // existing WHOOP flow — kicked off elsewhere on launch — uses it. For the seeded "my-whoop"
                // (peripheralId null, id "my-whoop") this is setWhoopPreferredAddress(null) and NO
                // setActiveDeviceId / NO scan / NO disconnect: byte-for-byte today's behaviour.
                pointWhoop(id, peripheralId)
            }
            else -> {
                // WHOOP → a DIFFERENT WHOOP: drop the current link, re-point, and reconnect.
                stopWhoop()
                pointWhoop(id, peripheralId)
                startWhoop()
            }
        }
    }

    /**
     * Apply the WHOOP targeting for the now-active WHOOP [id]. Always sets the preferred address (null for
     * the legacy "my-whoop" → connect to any WHOOP, unchanged). Re-points the sample deviceId ONLY for a
     * non-legacy WHOOP — the seeded "my-whoop" keeps the bootstrap-set id, so the single-WHOOP path never
     * calls setActiveDeviceId. Records [activeWhoopId] for future change detection. Mirrors macOS
     * `pointWhoop`.
     */
    private fun pointWhoop(id: String, peripheralId: String?) {
        setWhoopPreferredAddress(peripheralId)
        if (id != WhoopBleClient.DEFAULT_DEVICE_ID) {
            setWhoopActiveDeviceId(id)
        }
        activeWhoopId = id
    }

    /**
     * Active device is a generic strap. Pause WHOOP (once, on the WHOOP→strap edge) and run the isolated
     * [StandardHrSource] for this strap's deviceId. Re-running for the SAME id is a no-op.
     */
    private fun switchToStrap(id: String) {
        if (activeStrapId == id) return   // already streaming this strap → no churn
        if (!onStrap) stopWhoop()         // leaving WHOOP for the first strap → pause its BLE
        standardSource?.stop()            // strap→strap: stop the previous source first

        // Non-null in production (set at the composition root); only the JVM-test paths that never reach a
        // strap switch leave them null. Fail loudly rather than silently no-op if that invariant breaks.
        val ctx = requireNotNull(context) { "SourceCoordinator.context is required to run a strap source" }
        val repo = requireNotNull(repository) { "SourceCoordinator.repository is required to persist strap samples" }

        val source = StandardHrSource(
            context = ctx,
            deviceId = id,
            liveSink = liveSink,
            persist = { batch: StreamBatch, deviceId: String ->
                scope.launch { runCatching { repo.insert(batch, deviceId) } }
            },
        )
        source.scan()   // discover + connect the chosen strap on its own scanner/GATT
        standardSource = source
        activeStrapId = id
        onStrap = true
    }

    companion object {
        /**
         * Classify a device id as WHOOP vs a generic strap. WHOOP if the id is the canonical "my-whoop",
         * the registry row's `brand` is "WHOOP" (case-insensitive), OR the id is unknown — unknown ids
         * default to WHOOP so the coordinator stays dormant rather than ever stealing the WHOOP's BLE.
         * Mirrors Swift `SourceCoordinator.isWhoop`.
         */
        fun isWhoop(id: String, devices: List<PairedDeviceRow>): Boolean {
            if (id == WhoopBleClient.DEFAULT_DEVICE_ID) return true
            val device = devices.firstOrNull { it.id == id } ?: return true
            return isWhoop(device)
        }

        /** A device is WHOOP when its id is "my-whoop" or its brand is "WHOOP" (the seeded row's brand). */
        fun isWhoop(device: PairedDeviceRow): Boolean =
            device.id == WhoopBleClient.DEFAULT_DEVICE_ID ||
                device.brand.equals("WHOOP", ignoreCase = true)
    }
}
