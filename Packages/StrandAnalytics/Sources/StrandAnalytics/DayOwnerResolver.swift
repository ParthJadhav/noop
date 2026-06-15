import Foundation

/// Decides which single device owns a given day's displayed/scored metrics, so scores are never
/// computed from a mix of sources (invariant I2). Pure — the caller supplies candidates (each device
/// that has any data near the day, with a priority) and any locked override from the dayOwnership table.
public enum DayOwnerResolver {
    public struct Candidate: Equatable {
        public let deviceId: String
        public let priority: Int     // 0 = active strap, 1 = other live straps, 2 = imports (lower wins)
        public let hasData: Bool
        public init(deviceId: String, priority: Int, hasData: Bool) {
            self.deviceId = deviceId; self.priority = priority; self.hasData = hasData
        }
    }
    /// Returns the owning deviceId, or nil if no candidate has data for the day.
    public static func resolve(day: String, lockedOwner: String?, candidates: [Candidate]) -> String? {
        if let locked = lockedOwner { return locked }
        return candidates.filter { $0.hasData }.sorted { $0.priority < $1.priority }.first?.deviceId
    }
}
