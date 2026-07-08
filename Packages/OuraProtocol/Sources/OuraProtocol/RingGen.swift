import Foundation

// RingGen: per-generation capability + command-set selection. One transport handles all gens by
// swapping command sets, not code paths (per the architecture plan s5). The framing/auth/event-tag
// dictionary are generation-invariant (per OURA_PROTOCOL.md s7.2), so RingGen only drives:
//   - MTU clamp (203 vs 247)
//   - which characteristics to discover (gen5 extra notify chars, currently unused)
//   - the live-HR enable command set (verified on gen3, expected-same on gen4/5)
//   - the registered capability set surfaced to the app
//
// Platform-pure value type. Facts cited per OURA_PROTOCOL.md s7.

public enum OuraRingGen: String, Sendable, CaseIterable, Codable {
    case gen3
    case gen4
    case gen5

    /// Human-facing model name carried on PairedDevice.model (no schema change). The app recovers
    /// the generation via from(model:). Per architecture plan s5.
    public var displayName: String {
        switch self {
        case .gen3: return "Oura Ring 3"
        case .gen4: return "Oura Ring 4"
        case .gen5: return "Oura Ring 5"
        }
    }

    /// Negotiated ATT MTU for this generation. Per OURA_PROTOCOL.md s1.2.
    public var mtu: Int {
        switch self {
        case .gen3: return OuraGatt.mtuGen3
        case .gen4, .gen5: return OuraGatt.mtuGen45
        }
    }

    /// Max writable payload after the 3-byte ATT overhead. Per OURA_PROTOCOL.md s1.3.
    public var maxWritePayload: Int { mtu - OuraGatt.attOverhead }

    /// Whether this generation advertises the extra ...0004/5/6 characteristics. Only gen5 does, and
    /// v1 never writes to them (roles unconfirmed). Per OURA_PROTOCOL.md s1.2 / s7.2.
    public var hasExtraNotifyChars: Bool {
        switch self {
        case .gen3, .gen4: return false
        case .gen5: return true
        }
    }

    /// The numeric generation marker. The feature-mode master gate (setFeatureMode) requires
    /// generation > 2 (gen3+); gen <= 2 reject all feature-mode changes. All three supported gens
    /// satisfy this. Per OURA_PROTOCOL.md s7.1.
    public var generationNumber: Int {
        switch self {
        case .gen3: return 3
        case .gen4: return 4
        case .gen5: return 5
        }
    }

    /// True when this generation accepts feature-mode writes (live-HR / SpO2 enable). All supported
    /// generations are gen3+, so always true here; kept explicit for the s7.1 master-gate rule.
    public var supportsFeatureMode: Bool { generationNumber > 2 }

    /// Metrics this generation can register. Gen3+ all expose the same event-tag dictionary, so the
    /// capability set is currently uniform; kept per-gen so a future gen-specific gate is a one-line
    /// change. Per OURA_PROTOCOL.md s7.2.
    public var capabilities: Set<OuraMetric> {
        switch self {
        case .gen3, .gen4, .gen5:
            return [.hr, .hrv, .spo2, .skinTemp, .sleep]
        }
    }

    /// Best-effort generation guess from an advertised peripheral name. Oura does not reliably encode
    /// the generation in the BLE name, so this is a hint only; the wizard confirms via the model the
    /// user picks. Returns nil when nothing matches. Per architecture plan s5 (detection is best-effort).
    public static func recognise(advertisedName: String?) -> OuraRingGen? {
        guard let name = advertisedName?.lowercased() else { return nil }
        // Only treat as an Oura ring at all if the name carries the brand token.
        guard name.contains("oura") || name.contains("ring") else { return nil }
        if name.contains("5") { return .gen5 }
        if name.contains("4") { return .gen4 }
        if name.contains("3") || name.contains("horizon") { return .gen3 }
        return nil
    }

    /// Recover the generation from a stored PairedDevice.model string ("Oura Ring 3/4/5"). Defaults
    /// to gen3 (the verified-corpus generation) when the string is unrecognised, so an older row
    /// still maps to a usable command set. Per architecture plan s5.
    public static func from(model: String) -> OuraRingGen {
        let m = model.lowercased()
        if m.contains("5") { return .gen5 }
        if m.contains("4") { return .gen4 }
        if m.contains("3") { return .gen3 }
        return .gen3
    }
}

/// Capability metrics an Oura ring can register, parallel to the app-side Metric set. Kept local to
/// the protocol package so the package stays dependency-free; the app maps these onto its own Metric.
public enum OuraMetric: String, Sendable, CaseIterable, Codable {
    case hr
    case hrv
    case spo2
    case skinTemp
    case sleep
}
