import Foundation

/// A device the user has paired. `id` is the same string used as `deviceId` in every sample table's
/// `(deviceId, ts)` key — so a device's raw samples are already isolated by id, with no per-row source
/// column needed. The existing WHOOP keeps id "my-whoop" (no sample migration).
public struct PairedDevice: Equatable, Sendable, Identifiable {
    public let id: String                 // == deviceId in sample tables; e.g. "my-whoop", "polar-h10-1A2B"
    public var brand: String              // "WHOOP", "Polar", "Garmin", "Oura"
    public var model: String              // "WHOOP 4.0", "H10", "Forerunner 265", "Oura (import)"
    public var nickname: String?          // user-renamable; nil → show brand+model
    public var peripheralId: String?      // CBPeripheral.identifier.uuidString (iOS/Mac); nil until adopted
    public var sourceKind: SourceKind
    public var capabilities: Set<Metric>
    public var status: DeviceStatus
    public var addedAt: Int               // unix seconds
    public var lastSeenAt: Int

    public init(id: String, brand: String, model: String, nickname: String? = nil,
                peripheralId: String? = nil,
                sourceKind: SourceKind, capabilities: Set<Metric>, status: DeviceStatus,
                addedAt: Int, lastSeenAt: Int) {
        self.id = id; self.brand = brand; self.model = model; self.nickname = nickname
        self.peripheralId = peripheralId
        self.sourceKind = sourceKind; self.capabilities = capabilities; self.status = status
        self.addedAt = addedAt; self.lastSeenAt = lastSeenAt
    }

    /// A user nickname wins; otherwise "Brand Model" — but collapse to just the model when it already
    /// carries the brand (so a WHOOP whose model is also "WHOOP" reads "WHOOP", not "WHOOP WHOOP", and a
    /// future "WHOOP 4.0" model reads "WHOOP 4.0").
    public var displayName: String {
        if let nickname { return nickname }
        if model.isEmpty || model == brand { return brand }
        if model.localizedCaseInsensitiveContains(brand) { return model }
        return "\(brand) \(model)"
    }
}

public enum DeviceStatus: String, Sendable, CaseIterable { case active, paired, archived }

public enum SourceKind: String, Sendable, CaseIterable {
    case liveBLE, historyBLE, cloudImport, fileImport
    /// A live FTMS (Fitness Machine Service, 0x1826) gym machine — treadmill / indoor bike / rower /
    /// cross-trainer. Streams a live machine-data + HR session that records via the existing live-workout
    /// path. Additive: existing rows never carry this; only the gym-equipment wizard writes it.
    case ftms
    /// An EXPERIMENTAL Huami-family live HR source — Amazfit / Zepp (incl. Helio) and Xiaomi Mi Band.
    /// Reads the standard 0x180D HR service when exposed, else the documented Huami custom HR
    /// characteristic, else surfaces an honest "needs pairing we can't do" message. Best-effort, shipped
    /// behind the experimental add-device tier. Additive: only the experimental wizard writes it.
    /// (Garmin uses `liveBLE` — its live HR is the standard broadcast-HR path, no proprietary protocol.)
    case huami
    /// Apple Watch streamed via HealthKit (live HealthKit observer + background delivery). Apple-only,
    /// no Android twin. Additive: only the Apple Watch device registration writes it.
    case liveAppleWatch
    /// An EXPERIMENTAL live Oura Ring (gen 3/4/5) source over the ring's own clean-room BLE protocol
    /// (OuraProtocol package). Owns its OWN central/GATT, never the WHOOP path. Surfaces only the ring's
    /// decoded raw signals + open HRV/sleep-phase tags (capabilities {hr, hrv, spo2, skinTemp, sleep});
    /// NOOP computes its own Charge/Rest and never reads Oura's encrypted readiness/sleep scores. When a
    /// signal can't be read it stays "-" (Huami precedent), never faked. Additive (no DB migration): only
    /// the experimental add-device wizard's Oura path writes it.
    case oura
}

/// Canonical metric a source can provide. Drives capability-aware UI + the day-owner resolver.
public enum Metric: String, Sendable, CaseIterable, Codable {
    case hr, hrv, spo2, skinTemp, steps, sleep, strainLoad
}
