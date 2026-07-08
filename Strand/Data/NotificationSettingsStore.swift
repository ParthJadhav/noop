import Foundation
import Combine
import SwiftUI
import AppKit

// MARK: - Buzz pattern

/// Haptic pattern fired on the strap for a given app's notification.
/// All map to the on-device-confirmed graduated buzz (patternId 2); only the repeat count varies.
enum BuzzPattern: String, CaseIterable, Codable, Identifiable {
    case single, double, triple, long
    var id: String { rawValue }
    var label: String {
        switch self {
        case .single: return String(localized: "Single")
        case .double: return String(localized: "Double")
        case .triple: return String(localized: "Triple")
        case .long:   return String(localized: "Long")
        }
    }
    /// Repeat count handed to the haptic command.
    var loops: UInt8 {
        switch self {
        case .single: return 1
        case .double: return 2
        case .triple: return 3
        case .long:   return 5
        }
    }
}

// MARK: - Category

/// Grouping for the settings screen.
enum NotifCategory: String, CaseIterable, Identifiable {
    case email     = "Email"
    case messaging = "Messaging"
    case meetings  = "Meetings"
    case calendar  = "Calendar & Reminders"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .email:     return "envelope.fill"
        case .messaging: return "message.fill"
        case .meetings:  return "video.fill"
        case .calendar:  return "calendar"
        }
    }
    var defaultPattern: BuzzPattern {
        switch self {
        case .email:     return .double
        case .messaging: return .single
        case .meetings:  return .triple
        case .calendar:  return .double
        }
    }
}

// MARK: - App model

/// An installed, notification-capable app NOOP can mirror to the wrist.
struct NotifApp: Identifiable {
    let id: String          // resolved bundle id — also the persistence key
    let name: String
    let category: NotifCategory
    let icon: NSImage?
    let fallbackSymbol: String
}

/// Per-app alert preference.
struct AppAlertPref: Codable {
    var enabled: Bool
    var pattern: BuzzPattern
}

// MARK: - Store

/// Notification → wrist-alert preferences, persisted in UserDefaults.
/// When the (forthcoming) on-device notification watcher ships it will read these prefs via a
/// shared App Group suite (set up at that point); for now they back this screen's own state.
@MainActor
final class NotificationSettingsStore: ObservableObject {
    @Published var masterEnabled: Bool      { didSet { d.set(masterEnabled, forKey: K.master) } }
    @Published var onlyWhenWorn: Bool        { didSet { d.set(onlyWhenWorn, forKey: K.worn) } }
    @Published var quietHoursEnabled: Bool   { didSet { d.set(quietHoursEnabled, forKey: K.quiet) } }
    @Published var quietStartMinutes: Int    { didSet { d.set(quietStartMinutes, forKey: K.quietStart) } }
    @Published var quietEndMinutes: Int      { didSet { d.set(quietEndMinutes, forKey: K.quietEnd) } }
    @Published private var prefs: [String: AppAlertPref] { didSet { persistPrefs() } }

    /// Installed notification-capable apps, resolved once at init.
    let apps: [NotifApp]

    private let d = UserDefaults.standard
    private enum K {
        static let master     = "notif.masterEnabled"
        static let worn       = "notif.onlyWhenWorn"
        static let quiet      = "notif.quietHoursEnabled"
        static let quietStart = "notif.quietStartMinutes"
        static let quietEnd   = "notif.quietEndMinutes"
        static let prefs      = "notif.appPrefs"
    }

    init() {
        masterEnabled     = d.object(forKey: K.master) as? Bool ?? false  // opt-in, default OFF
        onlyWhenWorn      = d.object(forKey: K.worn) as? Bool ?? true
        quietHoursEnabled = d.object(forKey: K.quiet) as? Bool ?? false
        quietStartMinutes = d.object(forKey: K.quietStart) as? Int ?? 22 * 60   // 22:00
        quietEndMinutes   = d.object(forKey: K.quietEnd) as? Int ?? 7 * 60      // 07:00

        if let data = d.data(forKey: K.prefs),
           let decoded = try? JSONDecoder().decode([String: AppAlertPref].self, from: data) {
            prefs = decoded
        } else {
            prefs = [:]
        }

        apps = NotificationSettingsStore.sharedApps

        // Seed a default pref for any newly-discovered app (default OFF; opt-in).
        // We intentionally do NOT prune prefs for apps that are no longer installed: they are tiny,
        // bounded by the static catalog, and a temporarily-uninstalled app keeps its pattern across
        // a reinstall. All consumers iterate `apps`, never the raw `prefs` dict.
        var seeded = prefs
        for app in apps where seeded[app.id] == nil {
            seeded[app.id] = AppAlertPref(enabled: false, pattern: app.category.defaultPattern)
        }
        prefs = seeded
    }

    // MARK: Per-app access

    func pref(_ id: String) -> AppAlertPref {
        prefs[id] ?? AppAlertPref(enabled: false, pattern: .double)
    }
    func isEnabled(_ id: String) -> Bool { pref(id).enabled }
    func setEnabled(_ id: String, _ value: Bool) {
        var p = pref(id); p.enabled = value; prefs[id] = p
    }
    func pattern(_ id: String) -> BuzzPattern { pref(id).pattern }
    func setPattern(_ id: String, _ value: BuzzPattern) {
        var p = pref(id); p.pattern = value; prefs[id] = p
    }

    var enabledCount: Int { apps.filter { isEnabled($0.id) }.count }
    func apps(in category: NotifCategory) -> [NotifApp] { apps.filter { $0.category == category } }
    var activeCategories: [NotifCategory] { NotifCategory.allCases.filter { !apps(in: $0).isEmpty } }

    private func persistPrefs() {
        if let data = try? JSONEncoder().encode(prefs) { d.set(data, forKey: K.prefs) }
    }

    // MARK: Discovery

    /// Resolved once per process. The scan touches LaunchServices + decodes icons, so caching it
    /// avoids re-running on every navigation back to the screen (the view's @StateObject is rebuilt
    /// each visit). Lazily initialised on first access (here, from the MainActor init).
    static let sharedApps: [NotifApp] = NotificationSettingsStore.discoverApps()

    /// Catalog of notification-capable apps (name, category, candidate bundle ids, fallback glyph).
    /// Only those actually installed are returned, each with its real macOS app icon.
    private static func discoverApps() -> [NotifApp] {
        let catalog: [(name: String, category: NotifCategory, ids: [String], glyph: String)] = [
            ("Microsoft Outlook", .email,     ["com.microsoft.Outlook"],                              "envelope.fill"),
            ("Mail",              .email,     ["com.apple.mail"],                                     "envelope.fill"),
            ("WhatsApp",          .messaging, ["net.whatsapp.WhatsApp"],                              "message.fill"),
            ("Messenger",         .messaging, ["com.facebook.archon.developerID", "com.facebook.archon"], "message.fill"),
            ("Messages",          .messaging, ["com.apple.MobileSMS"],                                "message.fill"),
            ("Discord",           .messaging, ["com.hnc.Discord"],                                    "message.fill"),
            ("Slack",             .messaging, ["com.tinyspeck.slackmacgap"],                          "message.fill"),
            ("Telegram",          .messaging, ["ru.keepcoder.Telegram", "org.telegram.desktop"],      "paperplane.fill"),
            ("Signal",            .messaging, ["org.whispersystems.signal-desktop"],                  "message.fill"),
            // Teams notifications in the shade are overwhelmingly chats, @-mentions and channel
            // activity, which read as messages. Group it under Messaging with the chat glyph rather
            // than Meetings so the buzz pattern and icon match what actually arrives.
            ("Microsoft Teams",   .messaging, ["com.microsoft.teams2", "com.microsoft.teams"],        "message.fill"),
            ("Zoom",              .meetings,  ["us.zoom.xos"],                                        "video.fill"),
            ("FaceTime",          .meetings,  ["com.apple.FaceTime"],                                 "video.fill"),
            ("Calendar",          .calendar,  ["com.apple.iCal"],                                     "calendar"),
            ("Reminders",         .calendar,  ["com.apple.reminders"],                                "checklist"),
        ]

        let ws = NSWorkspace.shared
        var out: [NotifApp] = []
        for entry in catalog {
            var resolved: (id: String, url: URL)?
            for bid in entry.ids {
                if let url = ws.urlForApplication(withBundleIdentifier: bid) {
                    resolved = (bid, url); break
                }
            }
            guard let r = resolved else { continue }
            let icon = ws.icon(forFile: r.url.path)
            icon.size = NSSize(width: 64, height: 64)
            out.append(NotifApp(id: r.id, name: entry.name, category: entry.category,
                                icon: icon, fallbackSymbol: entry.glyph))
        }
        return out
    }
}
