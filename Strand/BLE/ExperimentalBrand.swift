import Foundation

/// CLEAN-ROOM best-effort recognition of the EXPERIMENTAL band families from an advertised device name.
///
/// This is pure (no CoreBluetooth) so it's unit-tested, and deliberately conservative: a name we don't
/// recognise returns `nil` rather than a wrong guess. NOTHING here fabricates data — it only labels a
/// discovered peripheral so the experimental add-device flow can show the honest per-brand guidance.
///
/// Recognition is by advertised-name substring only (the cheapest, most reliable public signal). We do
/// NOT claim a deeper protocol than we have: see each driver for what it can actually read.
public enum ExperimentalBrand: String, CaseIterable, Sendable, Equatable {
    /// Amazfit / Zepp / Huami family (incl. the Helio ring/band). Live HR is best-effort: standard
    /// 0x180D where exposed, else the documented Huami custom HR characteristic.
    case amazfit
    /// Xiaomi Mi Band (Huami-family). Older bands expose HR on a custom char; newer need an auth
    /// handshake we can't do — the driver surfaces that honestly rather than faking it.
    case miBand
    /// Garmin watch. Live HR is the STANDARD broadcast-HR path (0x180D) when the user enables
    /// "Broadcast Heart Rate" on the watch — there is no NOOP-proprietary Garmin protocol.
    case garmin
    /// Oura ring. No open live health stream — proprietary, syncs to Oura's own app. The driver makes
    /// the detection attempt and then points honestly at file import.
    case oura

    /// Best-effort brand from an advertised name. Returns `nil` for an unrecognised name (no wrong guess).
    public static func recognise(name: String) -> ExperimentalBrand? {
        // Fold diacritics before matching so Garmin's accented branding (e.g. "vívoactive", "fēnix")
        // is recognised the same as its ASCII advertised form ("vivoactive", "fenix"). A device can
        // advertise either, and an unfolded match would silently miss the accented name.
        let n = name.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        // Order matters: check the most specific tokens first so e.g. "Amazfit Helio" → amazfit and a
        // bare "Mi Band" → miBand. Mi Band is a Huami sub-brand, so we test its tokens before amazfit's.
        if n.contains("mi band") || n.contains("miband") || n.contains("smart band") || n.contains("xiaomi") {
            return .miBand
        }
        if n.contains("amazfit") || n.contains("zepp") || n.contains("helio") || n.contains("huami") {
            return .amazfit
        }
        if n.contains("garmin") || n.contains("forerunner") || n.contains("fenix") ||
            n.contains("vivoactive") || n.contains("venu") || n.contains("instinct") ||
            n.contains("epix") || n.contains("vivosmart") {
            return .garmin
        }
        if n.contains("oura") { return .oura }
        return nil
    }

    /// The brand label stored on the registry row / shown in the UI. Human, US-neutral, no claims.
    public var displayBrand: String {
        switch self {
        case .amazfit: return "Amazfit"
        case .miBand:  return "Mi Band"
        case .garmin:  return "Garmin"
        case .oura:    return "Oura"
        }
    }

    /// Whether this brand can stream LIVE heart rate at all in NOOP's experimental tier. `false` for Oura
    /// (no open live stream) — the wizard routes those to file import instead of pretending to connect.
    public var canStreamLiveHR: Bool {
        switch self {
        case .amazfit, .miBand, .garmin: return true
        case .oura:                      return false
        }
    }
}
