import Foundation
import Combine
import WhoopStore

// MARK: - DeviceRegistry
//
// Observable @MainActor cache over the synchronous `DeviceRegistryStore` (device-foundation
// Task 5). The UI observes this for the paired-device list + the currently active device; the
// app's `deviceId` is sourced from `activeDeviceId` so it's "the active device's id" rather than
// the hardcoded "my-whoop" literal. Behaviour is unchanged today — migration v15 seeds a single
// 'my-whoop' row as `.active`, so the active id is still "my-whoop".
//
// `DeviceRegistryStore` is synchronous (its own GRDB queue, internally serialized), so the reads
// here are plain synchronous calls; we keep failures non-fatal and fall back to the seeded defaults.
@MainActor
final class DeviceRegistry: ObservableObject {
    /// All paired devices (any status), oldest-added first — the store's `all()` ordering.
    @Published private(set) var devices: [PairedDevice] = []
    /// The active device's id. Defaults to "my-whoop" so callers have a safe value before the
    /// first `reload()` and if the registry can't be read.
    @Published private(set) var activeDeviceId: String = "my-whoop"

    private let store: DeviceRegistryStore

    init(store: DeviceRegistryStore) {
        self.store = store
    }

    /// Load the device list and active id from the store. Best-effort: on any error the published
    /// values are left untouched (keeping the safe "my-whoop" fallback), never crashing.
    func reload() {
        guard let rows = try? store.all() else { return }
        devices = rows
        if let active = rows.first(where: { $0.status == .active })?.id {
            activeDeviceId = active
        }
    }

    // MARK: - UI mutations (Devices screen)
    //
    // Each op delegates to the synchronous store, then `reload()`s so the published `devices` /
    // `activeDeviceId` reflect the change and the UI updates. Best-effort: a store failure leaves the
    // published state untouched (we never crash the UI on a write error).

    /// Add or upsert a paired device (the Add wizard's chosen strap). Refreshes the published list.
    func add(_ device: PairedDevice) {
        try? store.add(device)
        reload()
    }

    /// Make `id` the single active device. The store demotes whatever was active in the same
    /// transaction (invariant I1); changing `activeDeviceId` drives the `SourceCoordinator` to run the
    /// right live source.
    func setActive(_ id: String) {
        try? store.setActive(id)
        reload()
    }

    /// Archive (remove) a device: NOOP stops connecting to it, but its recorded data is kept. If the
    /// archived device was the active one, `activeDeviceId` is left as-is here — the caller decides the
    /// next active device (or leaves none active) and calls `setActive` explicitly.
    func archive(_ id: String) {
        try? store.archive(id)
        reload()
    }

    /// Rename a device. `name` nil/empty clears the nickname so it falls back to brand+model.
    func rename(_ id: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? store.rename(id, nickname: (trimmed?.isEmpty == false) ? trimmed : nil)
        reload()
    }

    /// Permanently delete every recorded sample/derived row for a device across all `deviceId`-keyed
    /// tables. Does NOT remove the registry row (that's `archive`); this only empties its recordings.
    ///
    /// Routed through the `WhoopStore` actor's `deleteAllData(deviceId:)`, so the heavy 16+-table delete
    /// runs on the actor's OWN (off-main) executor instead of blocking the main thread (this is a
    /// `@MainActor` cache). Calling the synchronous `DeviceRegistryStore` write directly here would run
    /// the whole transaction on the main actor and freeze the UI on a large device/Apple-Health dataset.
    /// Best-effort: a store failure leaves the recordings and published state untouched. Awaits the delete
    /// BEFORE `reload()` so the refreshed device list reflects the emptied recordings.
    func deleteDeviceData(_ id: String, store: WhoopStore) async {
        do {
            try await store.deleteAllData(deviceId: id)
        } catch {
            return
        }
        reload()
    }

    /// Adopt (or clear, when nil) the stable BLE identity for a device — the
    /// CBPeripheral.identifier.uuidString on iOS/Mac. Lets NOOP tell physical straps apart and map a
    /// connected peripheral back to its registry row. Refreshes the published list. Best-effort.
    func setPeripheralId(_ id: String, peripheralId: String?) {
        try? store.setPeripheralId(id, peripheralId: peripheralId)
        reload()
    }

    /// Find the paired device that has adopted a given BLE peripheral, if any. A plain read of the
    /// store (no reload) — returns nil on any error or when no row has adopted that peripheral yet.
    func device(forPeripheralId peripheralId: String) -> PairedDevice? {
        (try? store.device(forPeripheralId: peripheralId)) ?? nil
    }

    /// Refine the seeded neutral "WHOOP" model on the 'my-whoop' row to the strap the user actually
    /// picked (migration v15 seeds a placeholder the app can't fill at migration time, since the
    /// selected model lives in the app's UserDefaults). No-op when it already matches. Best-effort.
    func reconcileWhoopModel(_ model: String) {
        guard let rows = try? store.all(),
              let existing = rows.first(where: { $0.id == "my-whoop" }),
              existing.model != model else { return }
        var updated = existing
        updated.model = model
        try? store.add(updated)
        reload()
    }
}
