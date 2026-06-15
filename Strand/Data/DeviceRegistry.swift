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
