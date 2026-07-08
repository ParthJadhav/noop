import Foundation
import Combine
import WhoopStore
import OuraProtocol

/// Runs exactly ONE device's live BLE at a time, driven by `DeviceRegistry.activeDeviceId`.
///
/// WHOOP-FIRST, ZERO REGRESSION
/// ----------------------------
/// This coordinator is a deliberate **NO-OP for the single-WHOOP user** (one row, id "my-whoop",
/// `peripheralId` nil, no other device). That is the default state and EVERY state where no second
/// device is paired: WHOOP is active, `setPreferredPeripheral(nil)` keeps "connect to the first WHOOP
/// found", the WHOOP's deviceId stays "my-whoop", and the existing WHOOP flow (`BLEManager` via
/// `AppModel.scan(...)`) runs exactly as it does today. On a plain launch with one WHOOP it issues NO
/// scan, NO disconnect, NO re-point — the only side effect is one `setPreferredPeripheral(nil)`, which
/// is the BLEManager default and a no-op there.
///
/// It only ever *acts* beyond that when the registry has more than the seeded WHOOP:
///
///   • switching TO a generic strap → `stopWhoop()` (BLEManager's existing `disconnect()`), then
///     `start` the isolated `StandardHRSource` for that strap's deviceId.
///   • switching BACK to WHOOP     → `stop()` the `StandardHRSource`, re-point the WHOOP connection to
///     the now-active WHOOP, then `startWhoop()` (BLEManager's existing scan entry point).
///   • switching WHOOP → a DIFFERENT WHOOP → tear down the current WHOOP link, set its preferred
///     peripheral + active deviceId to the new WHOOP, and reconnect.
///
/// It never imports or references `BLEManager`: the WHOOP start/stop AND the WHOOP targeting hooks
/// (preferred peripheral, active deviceId) are injected closures from the app model, so the two BLE
/// flows stay fully decoupled (mirrors `StandardHRSource`'s isolation). The one input it observes off
/// the BLE engine — `connectedPeripheralUUID` — arrives as a plain publisher, not the manager itself.
@MainActor
final class SourceCoordinator: ObservableObject {

    // MARK: - Dependencies

    private let registry: DeviceRegistry
    private let live: LiveState
    /// Resolves the shared on-device store for the strap persist closure (opened lazily by the app's
    /// `Repository`, matching the existing async store lifecycle — we never force it open early).
    private let storeHandle: () async -> WhoopStore?
    /// Re-trigger WHOOP's EXISTING scan/connect entry point (e.g. `AppModel.scan()` → `BLEManager.connect`).
    private let startWhoop: () -> Void
    /// Pause WHOOP via its EXISTING teardown (e.g. `AppModel.disconnect()` → `BLEManager.disconnect`).
    private let stopWhoop: () -> Void
    /// Pin the WHOOP connection to a specific strap (nil = first WHOOP found = single-WHOOP default).
    /// Wraps `BLEManager.setPreferredPeripheral`. Called only on a WHOOP transition.
    private let setWhoopPreferredPeripheral: (String?) -> Void
    /// Re-point which device id live WHOOP samples store under. Wraps `BLEManager.setActiveDeviceId`.
    /// Called only when the active WHOOP is NOT the seeded "my-whoop" — the legacy path never invokes it.
    private let setWhoopActiveDeviceId: (String) -> Void
    /// The most-recently-connected WHOOP peripheral's uuid, from `BLEManager.$connectedPeripheralUUID`.
    private let connectedPeripheralUUID: AnyPublisher<String?, Never>
    /// Diagnostic sink for the ISOLATED generic-HR source's connect lifecycle. Wired at the composition
    /// root (`AppModel`) to the SAME strap log `BLEManager` writes to (`live.append(log:)`), so generic-HR
    /// lines land in the one log the user exports (issue #421 — the Polar/Wahoo/Coospo/Garmin-HRM path was
    /// previously invisible). Passed straight into `StandardHRSource`. Defaults to a no-op so existing
    /// call sites (and tests) compile unchanged.
    private let straplog: (String) -> Void

    // MARK: - State

    /// The lazily-created generic-strap source. nil until the first switch to a strap; reused after.
    private var standardSource: StandardHRSource?
    /// The lazily-created FTMS gym-equipment source. nil until the first switch to a gym machine. An FTMS
    /// device (sourceKind `.ftms`) is a non-WHOOP live source, so it runs through the SAME strap edge as
    /// `standardSource` — only the source object differs. Exactly one of the two is ever live at a time.
    private var ftmsSource: FTMSSource?
    /// The lazily-created EXPERIMENTAL Huami source (Amazfit / Zepp / Mi Band). nil until the first switch
    /// to a `.huami` device. Like the others it's a non-WHOOP live source sharing the same strap edge —
    /// exactly one of the non-WHOOP sources is ever live at a time.
    private var huamiSource: HuamiHRSource?
    /// The lazily-created EXPERIMENTAL Oura source (Oura Ring gen 3/4/5). nil until the first switch to a
    /// `.oura` device. Like the others it's a non-WHOOP live source sharing the same strap edge: exactly
    /// one of the non-WHOOP sources is ever live at a time. It owns its OWN `CBCentralManager` and never
    /// references `BLEManager`/`WhoopBleClient`, so the WHOOP path cannot regress.
    @Published private(set) var ouraSource: OuraLiveSource?
    /// The deviceId for which the user has granted explicit adopt consent (the wizard's irreversible gate +
    /// "Take over this ring?" confirm). The NEXT `startOuraSource` for THIS id builds its live source with
    /// `adoptIntent == true`, so the dangerous `0x24` key install can run for exactly that adopt session and
    /// nothing else. Cleared as soon as it is consumed (or when adopt is cancelled), so a later reconnect of
    /// the same ring is a normal read-only session that never re-installs a key.
    private var pendingAdoptDeviceId: String?
    /// The deviceId the active non-WHOOP source (`standardSource` / `ftmsSource` / `huamiSource` /
    /// `ouraSource`) runs for.
    private var activeStrapId: String?
    /// True once we've transitioned onto a generic strap. While false (the default / WHOOP-active
    /// state), switching to WHOOP is a pure no-op — we never issue a redundant WHOOP (re)scan.
    private var onStrap = false
    /// The WHOOP device id we're currently pointed at, set the first time WHOOP becomes active and on
    /// every WHOOP→WHOOP re-point. nil until the first WHOOP activation is handled. Lets us tell "same
    /// WHOOP, no change" (no churn) from "a DIFFERENT WHOOP became active" (re-point + reconnect).
    private var activeWhoopId: String?
    /// The uuid of the strap the WHOOP link is CURRENTLY connected to (from `connectedPeripheralUUID`).
    /// Lets a WHOOP→WHOOP make-active adopt IN PLACE when the newly-activated row is the same physical
    /// strap (#74 keep): a stop/start churn there would drop the live link and reconnect via scan. Cleared
    /// on disconnect (nil uuid).
    private var connectedWhoopUuid: String?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    /// - Parameters:
    ///   - registry: the Phase 1A device registry; `activeDeviceId` drives every transition.
    ///   - live: the shared `LiveState` the Live UI observes (fed by whichever source is running).
    ///   - storeHandle: resolves the shared `WhoopStore` for the strap persist closure.
    ///   - startWhoop: WHOOP's existing scan entry point (injected so we never touch `BLEManager`).
    ///   - stopWhoop: WHOOP's existing disconnect (injected for the same reason).
    ///   - setWhoopPreferredPeripheral: pin the WHOOP scan to one strap (nil = first found).
    ///   - setWhoopActiveDeviceId: re-point which id WHOOP samples store under (multi-WHOOP only).
    ///   - connectedPeripheralUUID: the BLE engine's last-connected WHOOP uuid, for identity adoption.
    ///   - straplog: connect-lifecycle diagnostics for the isolated `StandardHRSource`, wired to the same
    ///     strap log `BLEManager` uses (issue #421). Defaults to no-op so existing call sites compile.
    init(registry: DeviceRegistry,
         live: LiveState,
         storeHandle: @escaping () async -> WhoopStore?,
         startWhoop: @escaping () -> Void,
         stopWhoop: @escaping () -> Void,
         setWhoopPreferredPeripheral: @escaping (String?) -> Void,
         setWhoopActiveDeviceId: @escaping (String) -> Void,
         connectedPeripheralUUID: AnyPublisher<String?, Never>,
         straplog: @escaping (String) -> Void = { _ in }) {
        self.registry = registry
        self.live = live
        self.storeHandle = storeHandle
        self.startWhoop = startWhoop
        self.stopWhoop = stopWhoop
        self.setWhoopPreferredPeripheral = setWhoopPreferredPeripheral
        self.setWhoopActiveDeviceId = setWhoopActiveDeviceId
        self.connectedPeripheralUUID = connectedPeripheralUUID
        self.straplog = straplog
    }

    // MARK: - Wiring

    /// Begin observing `registry.activeDeviceId` AND the BLE engine's connected-peripheral uuid.
    /// `removeDuplicates()` collapses redundant emissions; the first activeDeviceId (WHOOP on a normal
    /// launch) is handled by `activeDeviceChanged` and, for the single WHOOP, does nothing but set the
    /// default preferred peripheral (nil) — no scan/disconnect churn. The connected-uuid sink drives
    /// first-connect identity adoption.
    func start() {
        registry.$activeDeviceId
            .removeDuplicates()
            .sink { [weak self] id in self?.activeDeviceChanged(to: id) }
            .store(in: &cancellables)

        connectedPeripheralUUID
            .removeDuplicates()
            .sink { [weak self] uuid in self?.connectedPeripheralChanged(to: uuid) }
            .store(in: &cancellables)
    }

    // MARK: - Transitions

    /// Resolve the device for `id` and reconcile which live source is running. Idempotent and guarded
    /// against redundant churn:
    ///   • An Apple Watch (`.liveAppleWatch`) → a HealthKit pseudo-device, NOT a BLE peripheral. Hand it
    ///     to the HealthKit-backed path and DO NOTHING to the BLE world (no scan/connect, and crucially
    ///     no `stopWhoop()`: the watch must never tear down a live WHOOP link).
    ///   • A WHOOP, same one we're already on (incl. the single-WHOOP first launch) → DO NOTHING new.
    ///   • A DIFFERENT WHOOP → re-point the WHOOP connection (preferred peripheral + deviceId) + reconnect.
    ///   • WHOOP active after a strap → stop the strap source + resume WHOOP.
    ///   • A generic strap → pause WHOOP + (re)start `StandardHRSource` for that strap's id.
    func activeDeviceChanged(to id: String) {
        // The Apple Watch is a HealthKit source with `peripheralId: nil` (see `AppleWatchDevice`): there is
        // no BLE peripheral to connect, and the M1 live read happens entirely in `HealthKitBridge`'s
        // observers + sync, off this BLE coordinator. Short-circuit BEFORE the WHOOP branch so we never
        // route it through `switchToStrap` (which would `stopWhoop()` and then BLE-scan a peripheral that
        // doesn't exist, tearing down the real WHOOP for nothing).
        if sourceKind(for: id) == .liveAppleWatch {
            switchToAppleWatch(id: id)
            return
        }

        if isWhoop(id) {
            switchToWhoop(id: id)
        } else {
            switchToStrap(id: id)
        }
    }

    /// Active device is the Apple Watch (a `.liveAppleWatch` HealthKit pseudo-device). It has no BLE
    /// peripheral, so this coordinator owns NONE of its data path: `HealthKitBridge` already streams it
    /// via HealthKit observers + background delivery and persists under the `apple-health` source. The one
    /// thing we MUST do here is leave the BLE world alone: do NOT `stopWhoop()` (a HealthKit device can't
    /// be allowed to drop a live WHOOP link) and do NOT start any BLE source. If a non-WHOOP BLE source
    /// (a strap / FTMS machine / Huami band) was the previously-active live source, tear it down so we're
    /// not streaming a strap that's no longer the active device, then mark ourselves off-strap so the
    /// next WHOOP activation resumes cleanly. The WHOOP, if it was active, is deliberately untouched.
    private func switchToAppleWatch(id: String) {
        if onStrap {
            tearDownNonWhoopSource()
            activeStrapId = nil
            onStrap = false
        }
        // No `stopWhoop()`, no BLE scan/connect: the watch lives entirely in HealthKitBridge.
    }

    /// Active device is a WHOOP (`id`). Three sub-cases, all churn-guarded:
    ///   • We were already on this exact WHOOP and not on a strap → pure no-op (the dormant default;
    ///     the single-WHOOP launch lands here and touches nothing but the initial preferred-peripheral).
    ///   • We were on a generic strap → stop that source and resume WHOOP, pointed at this WHOOP.
    ///   • We were on a DIFFERENT WHOOP → drop that WHOOP link and reconnect to this one.
    private func switchToWhoop(id: String) {
        // Already streaming this exact WHOOP with no strap in between → nothing to do.
        if !onStrap, activeWhoopId == id { return }

        let peripheralId = peripheralId(for: id)

        if onStrap {
            // Coming back from a generic strap / FTMS machine: tear that source down first.
            tearDownNonWhoopSource()
            activeStrapId = nil
            onStrap = false
            pointWhoop(at: id, peripheralId: peripheralId)
            startWhoop()
        } else if activeWhoopId == nil {
            // First WHOOP activation of the session (the normal launch path). Set the targeting so the
            // existing WHOOP flow — already kicked off elsewhere on launch — uses it. For the single
            // seeded "my-whoop" (peripheralId nil, id "my-whoop") this is setPreferredPeripheral(nil)
            // and NO setActiveDeviceId / NO scan / NO disconnect: byte-for-byte today's behaviour.
            pointWhoop(at: id, peripheralId: peripheralId)
        } else if let peripheralId, peripheralId.caseInsensitiveCompare(connectedWhoopUuid ?? "") == .orderedSame {
            // WHOOP → the SAME physical strap (make-active on the row we're already connected to): adopt IN
            // PLACE. A stop/start churn here would drop the #74-kept live link and force a scan reconnect.
            // Just re-point the targeting so samples land under this id; the connection is untouched.
            pointWhoop(at: id, peripheralId: peripheralId)
        } else {
            // WHOOP → a DIFFERENT WHOOP: drop the current link, re-point, and reconnect.
            stopWhoop()
            pointWhoop(at: id, peripheralId: peripheralId)
            startWhoop()
        }
    }

    /// Apply the WHOOP targeting for the now-active WHOOP `id`. Always sets the preferred peripheral
    /// (nil for the legacy "my-whoop" → connect to any WHOOP, unchanged). Re-points the sample deviceId
    /// ONLY for a non-legacy WHOOP — the seeded "my-whoop" keeps the bootstrap-set id, so the single-
    /// WHOOP path never calls `setActiveDeviceId`. Records `activeWhoopId` for future change detection.
    private func pointWhoop(at id: String, peripheralId: String?) {
        setWhoopPreferredPeripheral(peripheralId)
        if id != "my-whoop" {
            setWhoopActiveDeviceId(id)
        }
        activeWhoopId = id
    }

    /// Active device is a generic strap. Pause WHOOP (once, on the WHOOP→strap edge) and run the
    /// isolated `StandardHRSource` for this strap's deviceId. Re-running for the SAME id is a no-op.
    private func switchToStrap(id: String) {
        // Belt-and-braces: the Apple Watch is handled (and returned) in `activeDeviceChanged` before we
        // ever get here, but guard the case explicitly so a future caller reaching `switchToStrap`
        // directly can NEVER stop the WHOOP or BLE-scan a non-existent peripheral for a HealthKit device.
        if sourceKind(for: id) == .liveAppleWatch {
            switchToAppleWatch(id: id)
            return
        }

        guard activeStrapId != id else { return }   // already streaming this strap → no churn

        // Leaving WHOOP for the first non-WHOOP source: pause WHOOP's BLE via its existing teardown.
        if !onStrap { stopWhoop() }

        // Switching source→source: stop the previous non-WHOOP source before starting the new one.
        tearDownNonWhoopSource()

        // Route by sourceKind: an FTMS gym machine runs FTMSSource; an EXPERIMENTAL Huami device
        // (Amazfit / Zepp / Mi Band) runs the HuamiHRSource; an EXPERIMENTAL Oura ring runs the
        // OuraLiveSource; everything else is a generic HR strap on StandardHRSource. All are non-WHOOP
        // live sources sharing this same strap edge. (`.liveAppleWatch` never reaches this switch: it's
        // short-circuited above.)
        switch sourceKind(for: id) {
        case .ftms:  startFTMSSource(id: id)
        case .huami: startHuamiSource(id: id)
        case .oura:  startOuraSource(id: id)
        default:     startStandardSource(id: id)
        }
        activeStrapId = id
        onStrap = true
    }

    /// Start the isolated `StandardHRSource` for a generic HR strap `id`.
    private func startStandardSource(id: String) {
        let source = StandardHRSource(
            live: live,
            deviceId: id,
            persist: { [storeHandle] streams in
                Task { if let store = await storeHandle() { _ = try? await store.insert(streams, deviceId: id) } }
            },
            log: straplog,   // generic-HR lifecycle → the SAME exported strap log (issue #421)
            // Surface the generic strap's standard Battery Service (0x180F) charge the SAME place the
            // WHOOP strap battery shows (the Live/device status), via the shared LiveState funnel.
            onBattery: { [live] pct in live.setBattery(Double(pct)) })
        // CONNECT to the active strap's known peripheral, don't just scan. scan() only discovered + listed
        // it but never connected, so a Polar etc. showed as "found" yet never streamed (#421). connect()
        // reaches the cached peripheral by identifier (or scans-then-connects if not yet cached); a bare
        // scan is the fallback only when the registry row has no/invalid identifier.
        if let pid = peripheralId(for: id), let uuid = UUID(uuidString: pid) {
            source.connect(uuid)
        } else {
            source.scan()
        }
        standardSource = source
    }

    /// Start the isolated `FTMSSource` for a gym machine `id`. HR (when the machine reports it) rides the
    /// SAME `LiveState` channel, so the existing live-workout recorder scores it — no new scoring loop.
    private func startFTMSSource(id: String) {
        let source = FTMSSource(
            live: live,
            log: straplog,
            onBattery: { [live] pct in live.setBattery(Double(pct)) })
        if let pid = peripheralId(for: id), let uuid = UUID(uuidString: pid) {
            source.connect(uuid)
        } else {
            source.scan()
        }
        ftmsSource = source
    }

    /// Start the EXPERIMENTAL Huami source (Amazfit / Zepp / Mi Band) for `id`. HR (standard 0x180D when
    /// exposed, else the documented Huami custom characteristic) rides the SAME `LiveState` channel as the
    /// other sources, so the existing live UI + recorder handle it — no new scoring loop, no fabricated
    /// data (the source stays at "—" when it can't read a real HR).
    private func startHuamiSource(id: String) {
        let source = HuamiHRSource(
            live: live,
            deviceId: id,
            persist: { [storeHandle] streams in
                Task { if let store = await storeHandle() { _ = try? await store.insert(streams, deviceId: id) } }
            },
            log: straplog,
            onBattery: { [live] pct in live.setBattery(Double(pct)) })
        if let pid = peripheralId(for: id), let uuid = UUID(uuidString: pid) {
            source.connect(uuid)
        } else {
            source.scan()
        }
        huamiSource = source
    }

    /// Start the EXPERIMENTAL Oura source (Oura Ring gen 3/4/5) for `id`, driven by the clean-room
    /// `OuraProtocol.OuraDriver`. Decoded raw signals (HR / IBI / HRV / SpO2 / temp / sleep-phase / battery)
    /// ride the SAME `LiveState` + persist channels as the other sources, so NOOP scores the Oura day with
    /// its OWN Charge/Rest exactly like a WHOOP day, while Oura's encrypted readiness/sleep scores are never
    /// read or surfaced. The ring generation is recovered from the registry row's `model` string via
    /// `OuraRingGen.from(model:)`; the 16-byte install key is read from the Keychain via `OuraKeyStore`
    /// (nil → the source drives its HONEST `needsPairing` path and streams nothing, never a fake value).
    private func startOuraSource(id: String) {
        let ringGen = OuraRingGen.from(model: model(for: id) ?? "")
        // Adopt consent is consumed for exactly this start: only the session the user explicitly granted may
        // install a key (s3.2). Clearing it here means a later reconnect of the SAME ring is a normal
        // read-only session that re-authenticates with the now-stored key and never re-installs.
        let adoptIntent = (pendingAdoptDeviceId == id)
        pendingAdoptDeviceId = nil
        let source = OuraLiveSource(
            live: live,
            deviceId: id,
            ringGen: ringGen,
            authKey: { OuraKeyStore.read(deviceId: id) },
            persist: { [storeHandle] streams in
                Task { if let store = await storeHandle() { _ = try? await store.insert(streams, deviceId: id) } }
            },
            log: straplog,
            onBattery: { [live] pct in live.setBattery(Double(pct)) },
            adoptIntent: adoptIntent)
        if adoptIntent { straplog("Oura: adopt consent granted - this session may install NOOP's key") }
        if let pid = peripheralId(for: id), let uuid = UUID(uuidString: pid) {
            source.connect(uuid)
        } else {
            source.scan()
        }
        ouraSource = source
    }

    /// Grant explicit adopt consent for `deviceId` so the NEXT live Oura session for it (started when it
    /// becomes the active device) may run the dangerous key install (s3.2). Called by the wizard AFTER its
    /// irreversible-consent gate + "Take over this ring?" confirm, immediately before the ring is registered
    /// active. Per OURA_PROTOCOL.md s3.2 the install is a one-time, consent-gated provisioning write.
    func requestOuraAdopt(deviceId: String) {
        pendingAdoptDeviceId = deviceId
    }

    /// Stop whichever non-WHOOP source (standard strap, FTMS machine, Huami device, or Oura ring) is live,
    /// and drop the reference. Idempotent. Exactly one is ever live, but we stop all defensively.
    private func tearDownNonWhoopSource() {
        standardSource?.stop(); standardSource = nil
        ftmsSource?.stop(); ftmsSource = nil
        huamiSource?.stop(); huamiSource = nil
        ouraSource?.stop(); ouraSource = nil
    }

    // MARK: - Identity adoption

    /// The BLE engine connected to a WHOOP peripheral (`uuid`). Persist that stable identity onto the
    /// CURRENTLY ACTIVE device when it's a WHOOP and hasn't adopted one yet — so the legacy "my-whoop"
    /// learns its strap's id on first connect, and a freshly-paired WHOOP confirms its identity.
    ///
    /// Guards (so this never corrupts the registry):
    ///   • nil uuid (a disconnect/never-connected republish) → ignore.
    ///   • the active device is NOT a WHOOP (a generic strap is active) → ignore; this connection isn't ours.
    ///   • the active WHOOP already has a DIFFERENT non-nil peripheralId → a different strap connected:
    ///     - normally LOG it and do NOT clobber the stored identity (`didConnect` publishes pre-bond, so
    ///       `encryptedBond` is false — could be a transient/other strap; mis-mapping it would be wrong).
    ///     - BUT when this republish lands with `encryptedBond == true`, it's the BLEManager #52 stale-pin
    ///       handoff confirming a genuine bond on the live working strap (the only path that republishes
    ///       `connectedPeripheralUUID` post-bond). The stored pin is dead (it refused the bond N× in a row);
    ///       RE-ADOPT the working strap so we stop looping on the strap that won't bond. See #52.
    ///   • it already matches → nothing to write.
    private func connectedPeripheralChanged(to uuid: String?) {
        // Track the live strap's uuid for the WHOOP->WHOOP adopt-in-place skip (#74). nil is a
        // disconnect/never-connected republish: clear it so a later make-active can't wrongly match a stale
        // link, then fall through to the existing ignore.
        connectedWhoopUuid = uuid
        guard let uuid else { return }

        let activeId = registry.activeDeviceId
        guard isWhoop(activeId),
              let device = registry.devices.first(where: { $0.id == activeId }) else { return }

        switch device.peripheralId {
        case .none:
            // First connect for this WHOOP row → adopt the strap's stable identity.
            registry.setPeripheralId(activeId, peripheralId: uuid)
        case .some(uuid):
            break                               // already adopted this exact strap → nothing to do
        case .some(let existing):
            // A DIFFERENT strap connected under this WHOOP row. Re-adopt ONLY when this is the #52 stale-pin
            // handoff — i.e. the engine is genuinely encrypted-bonded to the strap whose id just arrived.
            // BLEManager only republishes `connectedPeripheralUUID` with `encryptedBond` true as that vetted
            // handoff (after the pinned strap refused the bond N× while this one bonded); an ordinary
            // pre-bond `didConnect` publish always carries `encryptedBond == false`, so the protective
            // "don't clobber" path below is preserved for every normal/transient different-strap connect.
            if live.encryptedBond {
                live.append(log: "Multi-WHOOP (#52): active device \(activeId) was pinned to strap \(existing) which refused to bond — re-adopting the working strap \(uuid).")
                registry.setPeripheralId(activeId, peripheralId: uuid)
            } else {
                live.append(log: "Multi-WHOOP: active device \(activeId) is registered to strap \(existing) but \(uuid) connected — not overwriting.")
            }
        }
    }

    // MARK: - Lookups / classification

    /// The stored `peripheralId` for a device id, if the registry knows it. nil for the legacy
    /// "my-whoop" until it adopts one (→ connect to any WHOOP, unchanged) and for an unknown id.
    private func peripheralId(for id: String) -> String? {
        registry.devices.first(where: { $0.id == id })?.peripheralId
    }

    /// The registered `sourceKind` for a device id, or nil if the registry doesn't know it. Routes the
    /// non-WHOOP switch to the right isolated source (`.ftms` → FTMSSource, `.huami` → HuamiHRSource,
    /// `.oura` → OuraLiveSource, anything else → StandardHRSource).
    private func sourceKind(for id: String) -> SourceKind? {
        registry.devices.first(where: { $0.id == id })?.sourceKind
    }

    /// The stored `model` string for a device id ("Oura Ring 3/4/5"), if the registry knows it. Used to
    /// recover the Oura ring generation via `OuraRingGen.from(model:)`; nil for an unknown id.
    private func model(for id: String) -> String? {
        registry.devices.first(where: { $0.id == id })?.model
    }

    /// Classify a device id as WHOOP vs a generic strap. WHOOP if the id is the canonical
    /// "my-whoop", or the registry row's `brand` is "WHOOP" (case-insensitive). Unknown ids default
    /// to WHOOP so the coordinator stays dormant rather than ever stealing the WHOOP's BLE.
    private func isWhoop(_ id: String) -> Bool {
        if id == "my-whoop" { return true }
        guard let device = registry.devices.first(where: { $0.id == id }) else { return true }
        return Self.isWhoop(device)
    }

    /// A device is WHOOP when its brand is "WHOOP" (the seeded `my-whoop` row's brand).
    static func isWhoop(_ device: PairedDevice) -> Bool {
        device.id == "my-whoop" || device.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
    }
}
