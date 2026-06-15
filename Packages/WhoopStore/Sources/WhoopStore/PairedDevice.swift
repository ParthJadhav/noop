import Foundation

/// A device the user has paired. `id` is the same string used as `deviceId` in every sample table's
/// `(deviceId, ts)` key — so a device's raw samples are already isolated by id, with no per-row source
/// column needed. The existing WHOOP keeps id "my-whoop" (no sample migration).
public struct PairedDevice: Equatable, Sendable, Identifiable {
    public let id: String                 // == deviceId in sample tables; e.g. "my-whoop", "polar-h10-1A2B"
    public var brand: String              // "WHOOP", "Polar", "Garmin", "Oura"
    public var model: String              // "WHOOP 4.0", "H10", "Forerunner 265", "Oura (import)"
    public var nickname: String?          // user-renamable; nil → show brand+model
    public var sourceKind: SourceKind
    public var capabilities: Set<Metric>
    public var status: DeviceStatus
    public var addedAt: Int               // unix seconds
    public var lastSeenAt: Int

    public init(id: String, brand: String, model: String, nickname: String? = nil,
                sourceKind: SourceKind, capabilities: Set<Metric>, status: DeviceStatus,
                addedAt: Int, lastSeenAt: Int) {
        self.id = id; self.brand = brand; self.model = model; self.nickname = nickname
        self.sourceKind = sourceKind; self.capabilities = capabilities; self.status = status
        self.addedAt = addedAt; self.lastSeenAt = lastSeenAt
    }

    public var displayName: String { nickname ?? "\(brand) \(model)" }
}

public enum DeviceStatus: String, Sendable, CaseIterable { case active, paired, archived }

public enum SourceKind: String, Sendable, CaseIterable { case liveBLE, historyBLE, cloudImport, fileImport }

/// Canonical metric a source can provide. Drives capability-aware UI + the day-owner resolver.
public enum Metric: String, Sendable, CaseIterable, Codable {
    case hr, hrv, spo2, skinTemp, steps, sleep, strainLoad
}
