import Foundation
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
import IOKit.ps
import Security
#endif

// MARK: - IOSDiagnostics
//
// iOS is a minefield of variables that quietly break a sideloaded health app: the OS/beta you're on,
// when the sideload certificate expires, whether Data Protection has the file vault locked (so history
// can't be written until you unlock after a reboot — the #222 class of bug), whether Background App
// Refresh is denied, and Low Power Mode throttling BLE. None of this shows up in a normal bug report.
//
// This probe captures all of it as a flat, copy-pasteable block of lines AND as typed fields, so the
// strap log carries the real iOS context and Settings can set honest expectations. The whole UIKit
// surface is iOS-only; the public API compiles on macOS (returning nils / "n/a") so shared callers —
// the strap-log header, the Settings panel — never need their own `#if`.

/// A small, platform-safe snapshot of the iOS runtime environment. On macOS every optional is nil and
/// `summaryLines()` returns an empty array, so callers can append it unconditionally.
struct IOSDiagnostics {

    /// Build a fresh snapshot of the current environment.
    ///
    /// Two of the iOS reads (`isProtectedDataAvailable`, `backgroundRefreshStatus`) are main-actor
    /// isolated. Every caller here runs on the main thread (a SwiftUI view body / a button tap), so we
    /// assume main isolation internally rather than annotating `capture()` `@MainActor` — that keeps it
    /// callable from a view's computed property and a `View` stored-property default without each call
    /// site needing its own hop. On macOS this is a plain synchronous return.
    static func capture() -> IOSDiagnostics {
        #if os(iOS)
        let (protectedData, backgroundRefresh): (Bool, String) = MainActor.assumeIsolated {
            (UIApplication.shared.isProtectedDataAvailable,
             Self.backgroundRefreshText(UIApplication.shared.backgroundRefreshStatus))
        }
        return IOSDiagnostics(
            deviceModel: Self.machineIdentifier(),
            osVersionString: ProcessInfo.processInfo.operatingSystemVersionString,
            isProtectedDataAvailable: protectedData,
            backgroundRefresh: backgroundRefresh,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isSideloaded: Self.isSideloadedBuild(),
            sideloadExpiry: Self.provisioningExpiryDate()
        )
        #elseif os(macOS)
        return IOSDiagnostics(
            osVersionString: ProcessInfo.processInfo.operatingSystemVersionString,
            macOnAC: Self.isOnAC(),
            macSigned: Self.isSignedAndNotarized(),
            macSandboxed: Self.isAppSandboxed()
        )
        #else
        return IOSDiagnostics()
        #endif
    }

    // MARK: Fields (all optional so the struct is meaningful on macOS too)

    /// Hardware model identifier, e.g. "iPhone16,2". nil on macOS.
    var deviceModel: String? = nil
    /// Full OS version string incl. the build number — the build suffix is the beta tell. nil on macOS.
    var osVersionString: String? = nil
    /// Data Protection state: false means the device is locked and protected files are unreadable —
    /// history can't be written/synced until the user unlocks once after a reboot (#222). nil on macOS.
    var isProtectedDataAvailable: Bool? = nil
    /// Background App Refresh: "Available" / "Denied" / "Restricted". nil on macOS.
    var backgroundRefresh: String? = nil
    /// Low Power Mode (throttles BLE + background work). nil on macOS.
    var isLowPowerMode: Bool? = nil
    /// Whether this looks like a sideloaded / dev build (embedded.mobileprovision present, no App Store
    /// receipt). nil on macOS.
    var isSideloaded: Bool? = nil
    /// The provisioning profile's expiry date, if a profile is embedded and parseable. nil otherwise.
    var sideloadExpiry: Date? = nil

    /// macOS: true when the Mac is on AC power, false on battery, nil off macOS. Net-new env (spec 3.4).
    var macOnAC: Bool? = nil
    /// macOS: best-effort "is this a signed plus notarized build". NOOP's macOS build is intentionally
    /// unsigned/un-notarized for anonymity, so this is expected false; we report it honestly. nil off macOS.
    var macSigned: Bool? = nil
    /// macOS: whether the App Sandbox is in effect (the AI-Coach network-entitlement gate). nil off macOS.
    var macSandboxed: Bool? = nil

    // MARK: Derived

    /// Whole days until the sideload certificate / provisioning profile expires (negative if already
    /// expired). nil when there's no embedded profile or it can't be parsed (e.g. App Store / macOS).
    func expiryDaysRemaining() -> Int? {
        guard let expiry = sideloadExpiry else { return nil }
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = cal.startOfDay(for: expiry)
        return cal.dateComponents([.day], from: from, to: to).day
    }

    /// A formatted, multi-line block describing the environment. Empty on macOS (the macOS strap-log
    /// header already carries OS + app version), so callers can append it unconditionally.
    func summaryLines() -> [String] {
        #if os(iOS)
        var lines: [String] = []
        lines.append("Device: \(deviceModel ?? "unknown")")
        if let os = osVersionString { lines.append("iOS: \(os)") }
        if let p = isProtectedDataAvailable {
            lines.append("Data Protection: \(p ? "unlocked (files readable)" : "LOCKED — unlock once after reboot so history can sync")")
        }
        if let bg = backgroundRefresh { lines.append("Background refresh: \(bg)") }
        if let lpm = isLowPowerMode { lines.append("Low Power Mode: \(lpm ? "ON (throttles background BLE)" : "off")") }
        if let side = isSideloaded { lines.append("Sideloaded build: \(side ? "yes" : "no (App Store / TestFlight)")") }
        if let days = expiryDaysRemaining() {
            if days < 0 {
                lines.append("Sideload expiry: EXPIRED \(-days) day\(abs(days) == 1 ? "" : "s") ago - re-sign to relaunch")
            } else {
                lines.append("Sideload expiry: \(days) day\(days == 1 ? "" : "s") remaining")
            }
        }
        return lines
        #elseif os(macOS)
        var lines: [String] = []
        if let os = osVersionString { lines.append("macOS: \(os)") }
        if let ac = macOnAC { lines.append("Power: \(ac ? "AC (plugged in)" : "battery")") }
        if let signed = macSigned {
            lines.append("Signed / notarized: \(signed ? "yes" : "no (unsigned build, Gatekeeper bypass expected)")")
        }
        if let sb = macSandboxed {
            lines.append("App Sandbox: \(sb ? "on (network entitlement gates the AI Coach)" : "off")")
        }
        return lines
        #else
        return []
        #endif
    }

    // MARK: - iOS-only probes

    #if os(iOS)

    /// The hardware model identifier (e.g. "iPhone16,2", "iPad14,1") via `uname` → `utsname.machine`.
    /// On the Simulator this returns the host arch (e.g. "arm64"); harmless for diagnostics.
    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    /// Human-readable Background App Refresh status.
    private static func backgroundRefreshText(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available:  return "Available"
        case .denied:     return "Denied (off in Settings)"
        case .restricted: return "Restricted (parental/MDM)"
        @unknown default: return "Unknown"
        }
    }

    /// Heuristic: a build is "sideloaded" (a dev / AltStore / free-Apple-ID install) when it ships an
    /// `embedded.mobileprovision` AND has no App Store receipt. App Store / TestFlight builds have a
    /// receipt and (for App Store) no embedded profile.
    private static func isSideloadedBuild() -> Bool {
        let hasProfile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
        let receiptExists: Bool = {
            guard let url = Bundle.main.appStoreReceiptURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }()
        return hasProfile && !receiptExists
    }

    /// Pull the `ExpirationDate` out of the embedded provisioning profile.
    ///
    /// The `.mobileprovision` file is a CMS / PKCS#7 (DER) blob that *wraps* an XML plist. Rather than
    /// pull in Security/CMS decoding, we slice the embedded plist out of the raw bytes — from the first
    /// `<?xml` to the closing `</plist>` — and parse that with `PropertyListSerialization`. Returns nil
    /// gracefully if the profile is absent, the markers are missing, or parsing fails.
    private static func provisioningExpiryDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }

        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)) else { return nil }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)

        guard let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any]
        else { return nil }

        return plist["ExpirationDate"] as? Date
    }

    #endif

    // MARK: - macOS-only probes

    #if os(macOS)

    /// True when the Mac is drawing AC power. Best-effort via IOKit power sources; false on battery,
    /// false if the state can't be read (degrade gracefully, never fabricate).
    private static func isOnAC() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSACPowerValue
            }
        }
        return false
    }

    /// Honest signing/notarization probe. NOOP's macOS build ships unsigned for anonymity, so this is
    /// expected to be false; we report what is true rather than claim a state we can't verify.
    private static func isSignedAndNotarized() -> Bool {
        // No code signature on an unsigned build: validity fails, so we report a truthful "no".
        return Bundle.main.executableURL.flatMap { url -> Bool? in
            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
                  let code = staticCode else { return false }
            let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)
            return status == errSecSuccess
        } ?? false
    }

    /// Whether the App Sandbox is active for this process (presence of the container env marker).
    private static func isAppSandboxed() -> Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    #endif
}
