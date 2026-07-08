import Foundation
import Combine
import WatchConnectivity
import WidgetKit
import StrandDesign

// MARK: - WatchScoreStore — the watch side of the phone->watch bridge
//
// Activates WCSession on the watch, receives the latest score snapshot the phone pushed via
// `updateApplicationContext` (latest-state semantics, no queue buildup), persists it into the shared
// App Group so the complication can read the same bytes, and reloads the complication timelines so the
// watch face matches the glance. The phone is the brain; this object never computes a score, it only
// carries the one the phone already earned.
//
// The published `snapshot` is what the glance binds to. It starts from whatever was last persisted to the
// App Group (so a relaunch shows the last-known scores immediately, with an honest "as of" age) and is
// nil only on a truly fresh install, which the glance renders as the "open NOOP on your iPhone" state.
final class WatchScoreStore: NSObject, ObservableObject, WCSessionDelegate {

    /// The latest snapshot the watch knows about. nil = nothing has ever synced (fresh install).
    @Published private(set) var snapshot: WatchScoreSnapshot?

    /// The shared App Group suite the watch app + its complication both read/write. The watch reads its
    /// own bundle's AppGroupIdentifier Info.plist key (injected from $(APP_GROUP_ID) in project.yml) so
    /// the value is never hard-coded in Swift, then falls back to the canonical group defined ONCE in
    /// the shared contract (StrandDesign) so the writer and readers can't desync on it.
    static let suiteName: String = {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? WatchScoreSnapshot.appGroupId
    }()

    /// The key the complication also reads. The single source of truth lives in the shared contract.
    static let storageKey = WatchScoreSnapshot.storageKey

    override init() {
        super.init()
        // Show the last-known snapshot straight away (honest about its age via the glance's "as of").
        snapshot = Self.loadPersisted()
        activate()
    }

    /// Bring up the WCSession so the phone can reach us. Guarded because the simulator / an unpaired
    /// state can report the session unsupported, in which case we simply run on the last persisted snapshot.
    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: Persistence (shared with the complication)

    /// Read the last snapshot the phone delivered, if any. The complication uses the same key.
    static func loadPersisted() -> WatchScoreSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Persist a snapshot into the shared group so the complication reads the SAME bytes the glance shows.
    /// They can never disagree because there is one source of truth.
    private func persist(_ snap: WatchScoreSnapshot) {
        guard let defaults = UserDefaults(suiteName: Self.suiteName),
              let data = try? JSONEncoder().encode(snap) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Apply a freshly received snapshot: store it, publish to the glance, refresh the complication.
    /// Hops to the main actor because it touches @Published state and WidgetCenter.
    private func apply(_ snap: WatchScoreSnapshot) {
        persist(snap)
        DispatchQueue.main.async {
            self.snapshot = snap
            // The phone just pushed new scores, so pull the complication timelines forward now rather
            // than waiting for WidgetKit's own cadence.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Decode a WatchScoreSnapshot out of a WatchConnectivity payload. The phone encodes the Codable
    /// snapshot to Data under "snapshot"; we tolerate a missing/garbled payload by simply ignoring it.
    private func decode(from payload: [String: Any]) -> WatchScoreSnapshot? {
        guard let data = payload["snapshot"] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // On activation the system hands us the most recent application context the phone set, even if it
        // was set while we were not running. Pick it up so a relaunch immediately reflects the latest scores.
        if let snap = decode(from: session.receivedApplicationContext) {
            apply(snap)
        }
    }

    /// The phone calls `updateApplicationContext` whenever its dashboard refreshes. Latest-state only, so
    /// we always have the freshest scores without a backlog of stale messages.
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let snap = decode(from: applicationContext) {
            apply(snap)
        }
    }

    // Required by the protocol on watchOS even though they are phone-side concerns. No-ops here.
    #if os(watchOS)
    func sessionReachabilityDidChange(_ session: WCSession) {}
    #endif
}
