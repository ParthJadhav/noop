import Foundation
import Combine
import CoreBluetooth
import Security
import WhoopProtocol
import WhoopStore
import OuraProtocol

/// EXPERIMENTAL, ISOLATED live-BLE source for the Oura ring (gen 3/4/5), driven by the clean-room
/// `OuraProtocol.OuraDriver`.
///
/// This is a real transport (it replaced an earlier honest dead-end probe): it decodes the ring's OWN
/// raw signals + open event tags (HR / IBI / HRV / SpO2 / temp / sleep-phase / battery), persists them
/// under the ring's `deviceId`, and lets NOOP compute its own Charge/Rest from those streams exactly like
/// a WHOOP day. It NEVER reads or surfaces Oura's encrypted readiness/sleep scores (honest-data
/// invariant), and when a signal can't be read it stays at "-", never a fabricated value (Huami precedent).
///
/// WHOOP-FIRST ISOLATION (identical to `StandardHRSource` / `HuamiHRSource`): this class runs its OWN
/// `CBCentralManager` and never imports, calls, or shares state with `BLEManager` / `WhoopBleClient`. The
/// WHOOP path cannot regress. The only shared surfaces are `LiveState` and the injected closures
/// (`persist`, `log`, `onBattery`). All BLE specifics live here; all protocol specifics live in the pure,
/// headless-testable `OuraDriver` (no CoreBluetooth in that package).
///
/// Honest about the handshake, step by step:
///   1. Scan for the Oura GATT service and filter discoveries by `OuraRingGen.recognise`.
///   2. Connect, discover the write/notify characteristics, enable notifications on ...0003.
///   3. Run the application auth challenge through `OuraDriver` (GetAuthNonce -> compute proof ->
///      Authenticate). The 16-byte install key is injected via `authKey`; when it is nil (or auth fails
///      because the ring is in factory reset / wrong key) we surface an HONEST `needsPairing` message and
///      stream NO data rather than faking one.
///   3a. ADOPT (factory-reset ring + explicit consent only): when the ring is in factory reset (auth status
///      `inFactoryReset` / no key) AND `adoptIntent == true`, the transport PROVISIONS a fresh 16-byte key:
///      it writes the dangerous `0x24` install, awaits the `0x25` OK ack, persists the key to `OuraKeyStore`,
///      then re-runs auth with the new key (s3.2). Without `adoptIntent` the dangerous opcode is NEVER sent;
///      we announce needs-pairing instead. A failed install is honest (Failed), never a fake success.
///   4. On auth success, run the gen-appropriate live-HR enable triplet; HR/IBI then streams as 0x2F
///      sub-op 0x28 pushes which the driver decodes.
///   5. Once streaming, also run a `GetEvents` HISTORY FETCH (s5) from the last-persisted cursor, and
///      periodically thereafter. Skin temp and SpO2 are SLEEP-ONLY on this hardware (neither ever arrives
///      as a live push, only as banked history), so the fetch is the only way last night's readings ever
///      reach the app. Fetched records are stamped with their real ring-time-anchored UTC (s5.5, from the
///      ring's own 0x42 time-sync event), NOT the wall-clock arrival time, so "last night" data is never
///      mis-timestamped as "now".
///   6. Decoded events map onto `Streams` via `OuraStreamMapping` and persist in batches; live HR also
///      feeds `LiveState`. Temp/SpO2/HRV/sleep-phase persist ONLY (no live surface - they are last-night
///      values, not a live readout). Battery is requested once streaming starts (`GetBattery`, 0x0C ->
///      0x0D) and feeds `onBattery`/`batteryPct`.
@MainActor
public final class OuraLiveSource: NSObject, ObservableObject {

    // MARK: - Public model

    /// An Oura ring seen during a scan.
    public struct DiscoveredRing: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
        /// Best-effort generation guess from the advertised name (confirmed by the model the user picks).
        public let detectedGen: OuraRingGen?
    }

    /// The coarse adopt outcome the wizard observes while it is in its "Taking over your ring" state, so it
    /// can drive Adopting -> success (on `.streaming`/connected) and Adopting -> an honest Failed (on
    /// `.failed`). It is ONLY meaningful for an adopt-intent connection; a read-only connect stays `.idle`
    /// until it streams (or surfaces `needsPairing`). PARITY: the Android twin exposes the same coarse
    /// adopt outcome the Compose wizard observes to leave its Adopting step.
    public enum AdoptPhase: Equatable, Sendable {
        case idle            // no adopt in flight (the default; a read-only connect never leaves this until streaming)
        case installingKey   // the dangerous 0x24 install was written; awaiting the 0x25 ack (an install IS running)
        case streaming       // auth (re-auth on the adopt path) succeeded and HR/IBI is streaming: adoption complete
        case failed          // an honest dead-end (no ack / ack != OK / re-auth failed / no key): never a fake success
    }

    @Published public private(set) var discovered: [DiscoveredRing] = []
    @Published public private(set) var scanning: Bool = false
    @Published public private(set) var batteryPct: Int? = nil
    /// Set to an HONEST explanation string when the ring needs a pairing/key handshake NOOP can't complete
    /// (no install key, or the ring is in factory reset, or the key was rejected). nil otherwise. The UI
    /// surfaces this instead of a fake reading. Cleared on stop/disconnect.
    @Published public private(set) var needsPairing: String? = nil
    /// The live adopt outcome (see `AdoptPhase`). The wizard observes this to leave its Adopting step. Reset
    /// to `.idle` on every connect/stop/disconnect so a stale outcome never drives a transition.
    @Published public private(set) var adoptPhase: AdoptPhase = .idle

    // MARK: - BLE UUIDs (from the platform-pure OuraGatt facts)

    /// The Oura base service (gen3/4/5). `OuraGatt` keeps the raw strings so the package stays
    /// CoreBluetooth-free; the app turns them into `CBUUID` here.
    private static let service = CBUUID(string: OuraGatt.serviceUUID)
    private static let writeChar = CBUUID(string: OuraGatt.writeCharacteristicUUID)
    private static let notifyChar = CBUUID(string: OuraGatt.notifyCharacteristicUUID)

    /// The `0x25` SetAuthKey-response outer opcode (`25 01 <status>`, status `0x00` = OK). Per
    /// OURA_PROTOCOL.md s3.2. This is the install-ack the adopt key-install awaits.
    private static let setAuthKeyRespOp: UInt8 = 0x25

    /// Local-time formatter for logging a decoded date/time next to a raw ring-tick cursor value, so a
    /// number like "1178203" reads as an actual date instead of an opaque tick count. Logging only.
    private static let cursorDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Decode a ring-tick cursor value to a human-readable local date/time via the driver's current
    /// session anchor (s5.5), or "no anchor yet" when none has arrived yet this session (honest: never
    /// guesses a time). Investigation/logging only.
    private func describeCursor(_ cursor: UInt32) -> String {
        guard let driver, let seconds = driver.unixSeconds(forRingTimestamp: cursor) else {
            return "no anchor yet"
        }
        return Self.cursorDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    // MARK: - Dependencies (injected - no BLEManager / WhoopBleClient reference)

    private let live: LiveState
    private let deviceId: String
    private let persist: (Streams) -> Void
    private let log: (String) -> Void
    private let onBattery: (Int) -> Void
    /// The ring generation (carried on `PairedDevice.model`, recovered via `OuraRingGen.from(model:)`).
    /// Selects the MTU clamp, which characteristics to discover, and the live-HR command set.
    private let ringGen: OuraRingGen
    /// Supplies the 16-byte application install key (from the Keychain) for this ring, or nil. A nil key
    /// drives the honest `needsPairing` path: the driver answers `.needsKeyInstall` and we never fake data.
    private let authKey: () -> Data?
    /// When false (the wizard's discovery-only scanner) this source never writes `LiveState` or persists.
    private let feedsLive: Bool
    /// EXPLICIT, USER-GRANTED adopt consent for THIS connection. Default FALSE. The dangerous installKey
    /// opcode (`0x24`) may be sent ONLY when this is true: it is what gates the post-factory-reset key
    /// provisioning (s3.2). It is set true by the adopt flow AFTER the wizard's irreversible-consent gate
    /// (the consent tick AND the "Take over this ring?" confirm), and it gates the driver's `allowKeyInstall`
    /// so a read-only / Advanced-key connection can NEVER install a key. Set once at construction (the
    /// coordinator builds a fresh source per connection, so a new value just means a new source).
    private let adoptIntent: Bool

    // MARK: - Protocol state machine (pure - holds NO BLE handle)

    /// The transport-agnostic driver. Re-created on each connect so a fresh session re-runs auth (the
    /// app key is session-scoped). nil until a connection begins.
    private var driver: OuraDriver?
    /// Reassembles notification fragments into complete TLV inner records across feeds.
    private let reassembler = OuraReassembler()

    /// Logs the FIRST live HR sample of a connection only (never every push); reset on stop/disconnect.
    private var loggedFirstHR = false
    /// Logs the FIRST skin-temp sample DECODED THIS SESSION only (never every record); reset on
    /// stop/disconnect. These are last-night values from the history fetch, not live pushes, but we still
    /// only want one log line, not one per sample. Twin of `loggedFirstHR`.
    private var loggedFirstTemp = false
    /// Logs the FIRST SpO2 sample decoded this session only. Twin of `loggedFirstTemp`.
    private var loggedFirstSpo2 = false
    /// Logs the FIRST ring-time -> UTC anchor of this session only (s5.5); reset on stop/disconnect.
    private var loggedAnchor = false
    /// Tier-B (UNVERIFIED) kinds ("activity" / "real_steps" / "sleep_summary" / "spo2_smoothed") already
    /// logged this session, so a repeated tag logs once per KIND, not once per record. INVESTIGATION
    /// ONLY (see the `allowTierB: true` comment at driver construction) - the log is how we collect raw
    /// captures to validate these layouts; nothing here ever persists or scores. Reset on stop/disconnect.
    private var loggedTierBKinds: Set<String> = []
    /// History-fetched events decoded BEFORE a ring-time -> UTC anchor exists this session, held here
    /// (with their own ring timestamp) until the anchor lands (`drainPendingAnchorEvents`), so they get
    /// their real historical time instead of a premature wall-clock guess. The ring's 0x42 time-sync can
    /// arrive anywhere in a history-fetch stream, not necessarily first, so records that land before it
    /// are parked here and re-stamped the moment an anchor lands. Drained with an honest wall-clock
    /// fallback at teardown if no anchor ever arrived this session (never silently dropped). Reset on
    /// stop/disconnect.
    private var pendingAnchorEvents: [(event: OuraEvent, ringTimestamp: UInt32)] = []
    /// True once the live-HR stream has been requested, so the disconnect handler can tell "we never got
    /// authenticated/streaming" (-> honest note) from "the link just dropped".
    private var reachedStreaming = false
    /// The freshly-generated 16-byte key written to the ring during an adopt key install. Held in memory
    /// ONLY between writing the `0x24` install and receiving the `0x25` ack: it is persisted to the keystore
    /// ONLY on an OK ack (so a failed/absent ack never leaves a key the next session would wrongly trust).
    /// Cleared on stop/disconnect/failure.
    private var pendingInstallKey: Data?

    // MARK: - CoreBluetooth state (OWN central, separate from WHOOP)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    /// A peripheral asked to connect before `centralManagerDidUpdateState` reported `.poweredOn`.
    private var pendingConnectID: UUID?
    /// Peripherals retained by identifier so a chosen one survives until connection (exact
    /// StandardHRSource seenPeripherals/pendingConnectID/retrievePeripherals pattern).
    private var seenPeripherals: [UUID: CBPeripheral] = [:]

    // MARK: - Auto-reconnect (#912)

    /// The paired ring we should keep re-reaching. Set by `connect(_:)`, cleared by `stop()`. While it is
    /// non-nil an INVOLUNTARY drop (or a failed connect) re-issues a connect on a capped backoff, so the
    /// ring comes back on its own once it's in range again, exactly like the WHOOP strap's auto-reconnect
    /// (BLEManager). WHOOP has this loop; the non-WHOOP sources never did, so a dropped Oura ring stayed
    /// down until a manual reconnect. This never touches the WHOOP path or the shared central queue.
    private var reconnectID: UUID?
    /// True while a teardown was USER/COORDINATOR-initiated (`stop()`), so the disconnect handler suppresses
    /// the auto-reconnect (mirrors BLEManager's `intentionalDisconnect`). Cleared on every `connect(_:)`.
    private var intentionalDisconnect = false
    /// Consecutive involuntary reconnect attempts, driving the capped-exponential backoff (3, 6, 12, 24,
    /// 48, 60s). Reset to 0 on a successful connect and on an explicit `connect(_:)`. Matches BLEManager
    /// (#414) and the Android `ReconnectBackoff` so a ring genuinely out of range doesn't hammer BLE.
    private var failedReconnectAttempts = 0

    /// Next backoff delay, capped at 60s, matching BLEManager's `min(60, 3 * 2^(n-1))` and the Android twin.
    private func nextReconnectDelay() -> TimeInterval {
        min(60.0, 3.0 * pow(2.0, Double(max(0, failedReconnectAttempts - 1))))
    }

    /// Schedule an auto-reconnect to the paired ring after a backoff delay, unless the teardown was
    /// intentional or there is no known ring. Guarded again inside the deferred block: a `stop()` that
    /// lands in the meantime cancels the pending reconnect (it re-checks `intentionalDisconnect` and that
    /// the target is unchanged), so a deliberate teardown never races a stale reconnect.
    private func scheduleReconnect() {
        guard !intentionalDisconnect, let id = reconnectID else { return }
        failedReconnectAttempts += 1
        let delay = nextReconnectDelay()
        log("Oura: reconnecting in \(Int(delay))s (attempt \(failedReconnectAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalDisconnect, self.reconnectID == id else { return }
            self.connect(id)
        }
    }

    // MARK: - History fetch (GetEvents, s5) - the ONLY path skin temp / SpO2 / HRV / sleep-phase ever
    // arrive by. Neither temp nor SpO2 is ever pushed live on this hardware; both are banked overnight and
    // retrievable only by asking the ring for its history.

    /// The GetEvents cursor to resume from, loaded from `OuraHistoryCursorStore` on connect and advanced
    /// as `0x11` summaries arrive. 0 = fetch everything the ring has banked (first-ever connect for this
    /// ring; OURA_PROTOCOL.md s5.1).
    private var historyCursor: UInt32 = 0
    /// Periodic re-fetch while connected, so an overnight-connected session (or one left open after a nap)
    /// picks up freshly-banked sleep data without needing a reconnect. Mirrors BLEManager's ~15 min
    /// periodic WHOOP history-offload floor.
    private var historyFetchTimer: Timer?
    private let historyFetchInterval: TimeInterval = 900

    /// Kick a history-fetch pass at the current cursor, but ONLY when the driver is idle-streaming (never
    /// overlaps a fetch already in flight - the driver's own phase is the guard, so this is safe to call
    /// both right after reaching `.streaming` and from the periodic timer).
    private func fetchHistoryIfIdle() {
        guard let driver, driver.phase == .streaming else { return }
        log("Oura: fetching history from cursor \(historyCursor) (\(describeCursor(historyCursor)))")
        advance(.startHistoryFetch(cursor: historyCursor))
    }

    private func startHistoryFetchTimer() {
        stopHistoryFetchTimer()
        let t = Timer.scheduledTimer(withTimeInterval: historyFetchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchHistoryIfIdle() }
        }
        historyFetchTimer = t
    }

    private func stopHistoryFetchTimer() {
        historyFetchTimer?.invalidate()
        historyFetchTimer = nil
    }

    /// Handle a `0x11` GetEvents response (OURA_PROTOCOL.md s5.2): persist the advanced cursor (so a LATER
    /// connection resumes rather than re-fetching everything) and drive the driver's cursor-loop state
    /// machine, which asks for another ack-fetch while `moreData` or returns to `.streaming` once caught up.
    ///
    /// The ring's terminal "no more data" response (moreData=false, status 0x00) zero-fills the cursor
    /// field, whereas a mid-fetch response (moreData=true) carries a real advancing nonzero cursor. So the
    /// cursor is only trusted/persisted while the response is actually carrying new data - persisting the
    /// terminal zero would reset the cursor to 0 on every fetch and force a full backlog re-fetch forever.
    ///
    /// A cursor persisted from one BLE connection can come back SMALLER on the next connection's first real
    /// cursor: `ringTimestamp = (session << 16) | counter` (OURA_PROTOCOL.md s2.3), and the ring's internal
    /// `session` component can shift across reconnects/restarts. This is the same class of problem s5.5
    /// documents for the UTC anchor (ring-start with rt regression -> invalidate anchor). Resuming from a
    /// cursor whose session no longer matches the ring's current one is not a real resume - the ring just
    /// re-dumps its whole backlog anyway - so we detect the regression and reset to an honest, explicit 0
    /// rather than feed the ring a now-meaningless reference.
    private func handleHistorySummary(_ summary: (cursor: UInt32, moreData: Bool)) {
        if summary.moreData {
            if summary.cursor < historyCursor {
                log("Oura: ring-time regression detected (fetch cursor \(summary.cursor) [\(describeCursor(summary.cursor))] < persisted \(historyCursor) [\(describeCursor(historyCursor))]) - the ring's session likely reset; resetting our cursor to 0")
                historyCursor = 0
                OuraHistoryCursorStore.save(0, deviceId: deviceId)
            } else {
                historyCursor = summary.cursor
                OuraHistoryCursorStore.save(summary.cursor, deviceId: deviceId)
            }
        } else {
            log("Oura: history fetch caught up (cursor \(historyCursor) [\(describeCursor(historyCursor))])")
        }
        advance(.historyCursorAdvanced(cursor: summary.cursor, moreData: summary.moreData))
    }

    // MARK: - Sample buffer

    /// Buffered decoded events, flushed to `persist` in batches to keep the write path off the
    /// per-notification hot loop. Each entry carries its own `ts` (unix seconds): live-push events (HR,
    /// IBI, battery) are stamped at wall-clock arrival time; history-fetched events (temp, SpO2, HRV,
    /// sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) when an anchor is available,
    /// so last night's data is never mis-recorded as happening right now.
    private var buffer: [(events: [OuraEvent], ts: Int)] = []
    private var lastFlush: Date = .init()
    private let flushCount = 30
    private let flushInterval: TimeInterval = 30

    // MARK: - Live-HR re-engagement

    /// Daytime-HR auto-reverts after ~20 s (OURA_PROTOCOL.md s5.7), so while a live session is open we
    /// re-send the enable+subscribe every ~15 s. nil when no session is streaming.
    private var reengageTimer: Timer?
    private let reengageInterval: TimeInterval = 15

    // MARK: - Init

    /// - Parameters:
    ///   - live: the shared `LiveState` the Live UI observes.
    ///   - deviceId: the datastore device id these samples are attributed to.
    ///   - ringGen: the ring generation (selects MTU clamp + command set).
    ///   - authKey: supplies the 16-byte install key from the Keychain, or nil to drive `needsPairing`.
    ///   - persist: wired by the app to `store.insert(_, deviceId:)`. Called on the main actor.
    ///   - log: connect-lifecycle diagnostics sink, wired at the composition root to the same strap log
    ///     `BLEManager` writes to (issue #421). Every line is prefixed "Oura: ". Defaults to a no-op.
    ///   - onBattery: fired with the ring's battery percent (0-100). Default no-op.
    ///   - feedsLive: when false (the discovery-only wizard scanner) this source never touches LiveState
    ///     or persists. Default true.
    ///   - adoptIntent: EXPLICIT user-granted adopt consent for this connection. Default FALSE. Only when
    ///     true may the dangerous `0x24` installKey opcode ever be sent (the post-factory-reset provisioning,
    ///     s3.2). The standard live path leaves it false (read-only / Advanced-key), so a key is NEVER
    ///     installed outside the wizard's irreversible-consent adopt flow.
    public init(live: LiveState,
                deviceId: String,
                ringGen: OuraRingGen,
                authKey: @escaping () -> Data?,
                persist: @escaping (Streams) -> Void = { _ in },
                log: @escaping (String) -> Void = { _ in },
                onBattery: @escaping (Int) -> Void = { _ in },
                feedsLive: Bool = true,
                adoptIntent: Bool = false) {
        self.live = live
        self.deviceId = deviceId
        self.ringGen = ringGen
        self.authKey = authKey
        self.persist = persist
        self.log = log
        self.onBattery = onBattery
        self.feedsLive = feedsLive
        self.adoptIntent = adoptIntent
        super.init()
        // Dedicated queue-less central -> callbacks arrive on the main queue, matching @MainActor.
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    /// Scan for Oura rings advertising the Oura GATT service, keeping only ones the ring-gen recogniser
    /// accepts as an Oura ring.
    public func scan() {
        discovered.removeAll()
        seenPeripherals.removeAll()
        scanning = true
        needsPairing = nil
        log("Oura: scanning for an Oura ring (service \(OuraGatt.serviceUUID))")
        guard central.state == .poweredOn else {
            log("Oura: Bluetooth not powered on (state=\(central.state.rawValue)) - scan deferred until ready")
            return
        }
        central.scanForPeripherals(withServices: [Self.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    // MARK: - Connecting

    /// Connect to the chosen ring and start the auth -> enable -> stream flow. Mirrors the
    /// StandardHRSource cached-by-identifier-first, else scan-then-connect pattern.
    public func connect(_ id: UUID) {
        stopScan()
        needsPairing = nil
        // Remember the paired ring so an involuntary drop auto-reconnects to it (#912). An explicit connect
        // is never the intentional-teardown case, so clear the suppression flag.
        reconnectID = id
        intentionalDisconnect = false
        let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            // Never seen by this Mac/iPhone yet -> remember it and scan; didDiscover connects on sight.
            pendingConnectID = id
            log("Oura: ring \(id) not cached yet - scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            pendingConnectID = id
            log("Oura: Bluetooth not powered on - connect to \(id) deferred until ready")
            return
        }
        log("Oura: connecting to \(id)")
        central.connect(p, options: nil)
    }

    /// Tear down: cancel the connection, stop scanning, flush, clear all transient state. Idempotent.
    public func stop() {
        // A deliberate teardown (device switch / removal) must NOT auto-reconnect: mark it intentional and
        // drop the reconnect target so any pending backoff bails and no fresh one is scheduled (#912).
        intentionalDisconnect = true
        reconnectID = nil
        failedReconnectAttempts = 0
        stopScan()
        pendingConnectID = nil
        stopReengageTimer()
        stopHistoryFetchTimer()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeCharacteristic = nil
        // Drain BEFORE driver.stop() clears its anchor, so a pending event still gets a real anchored
        // time if one exists rather than always falling back to wall-clock at teardown.
        drainPendingAnchorEvents()
        driver?.stop()
        driver = nil
        reassembler.reset()
        loggedFirstHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        reachedStreaming = false
        pendingInstallKey = nil
        adoptPhase = .idle
        batteryPct = nil
        needsPairing = nil
        flush()                       // persist anything still buffered
        if feedsLive { live.connected = false; live.streamingLiveHR = false }
    }

    // MARK: - Driver wiring

    /// Write the bytes for each command the driver returned, logging the label only (never an address).
    private func write(_ commands: [OuraCommand]) {
        guard let peripheral, let writeCharacteristic else { return }
        let mtuPayload = ringGen.maxWritePayload   // gen-appropriate clamp (gen3=200, gen4/5=244)
        for cmd in commands {
            guard cmd.bytes.count <= mtuPayload else {
                log("Oura: skipping \(cmd.label) - \(cmd.bytes.count)B exceeds the \(mtuPayload)B write window")
                continue
            }
            log("Oura: -> \(cmd.label)")
            peripheral.writeValue(Data(cmd.bytes), for: writeCharacteristic, type: .withoutResponse)
        }
    }

    /// Advance the driver with a transition and write whatever it asks for next.
    private func advance(_ transition: OuraTransition) {
        guard let driver else { return }
        let commands = driver.nextStep(after: transition)
        write(commands)
        // Surface the driver's coarse phase honestly into the UI state.
        switch driver.phase {
        case .needsKeyInstall:
            // A factory-reset ring (auth status inFactoryReset) or no key available. The dangerous key
            // install is the ONLY thing that recovers it, and ONLY with explicit adopt consent: provision
            // when `adoptIntent`, otherwise stay honest (never loop the dangerous command).
            if adoptIntent {
                provisionKeyInstall()
            } else {
                announceNeedsPairing(reason: .factoryResetOrNoKey)
            }
        case .authFailed(let status):
            announceNeedsPairing(reason: .authFailed(status))
        case .streaming:
            if !reachedStreaming {
                reachedStreaming = true
                adoptPhase = .streaming   // re-auth after an install (or a normal auth) reached the stream: adoption complete
                pendingInstallKey = nil   // an OK ack already persisted the key; nothing left in flight
                if feedsLive { live.streamingLiveHR = true }   // drive the green menu-bar STREAMING pill (no WHOOP bond)
                log("Oura: live-HR enabled - streaming HR / IBI")
                startReengageTimer()
                startHistoryFetchTimer()
                fetchHistoryIfIdle()   // pull last night's banked temp/SpO2/HRV/sleep-phase right away
                write([OuraCommands.getBattery()])   // ask once HR streams; the 0x0D reply routes to onBattery
            }
        default:
            break
        }
    }

    // MARK: - Adopt key-install handshake (s3.2) - ONLY ever reached with explicit adopt consent

    /// PROVISION a fresh key into a factory-reset ring (OURA_PROTOCOL.md s3.2). Reached ONLY from `advance`
    /// when `driver.phase == .needsKeyInstall` AND `adoptIntent == true`. Steps: (1) generate a fresh
    /// cryptographically-random 16-byte key; (2) ask the driver for the dangerous `24 10 <key>` install
    /// command (the driver's own `allowKeyInstall`/phase gate is the second guard) and write it; (3) hold the
    /// key in memory and mark `.installingKey` (an install IS now running). The key is NOT persisted yet: it
    /// is written to the keystore only once the ring acks OK (`handleKeyInstallAck`), so a failed install
    /// never leaves a key the next session would wrongly trust. On any build/RNG failure we stay honest.
    private func provisionKeyInstall() {
        guard adoptIntent else { return }                 // belt-and-braces: never provision without consent
        guard pendingInstallKey == nil else { return }    // an install is already in flight; don't double-send
        guard let driver else { return }
        guard let key = Self.randomInstallKey() else {
            announceNeedsPairing(reason: .installFailed("could not generate a key"))
            return
        }
        guard let cmd = driver.beginKeyInstall(key: [UInt8](key)) else {
            // The driver refused (wrong phase / not allowed / build failed): stay honest, never retry blind.
            announceNeedsPairing(reason: .installFailed("the install command could not be prepared"))
            return
        }
        pendingInstallKey = key
        adoptPhase = .installingKey
        log("Oura: installing NOOP's key on the reset ring")
        write([cmd])
    }

    /// Handle the ring's `0x25` SetAuthKey ack (OURA_PROTOCOL.md s3.2: `25 01 00`, status byte `0x00` = OK).
    /// On OK: persist the freshly-provisioned key under this `deviceId` (so every future session authenticates
    /// with it), then drive the driver's `keyInstallAcknowledged()` to re-run the auth handshake (GetAuthNonce
    /// then Authenticate) with the NEW key. On a non-OK status (or a missing pending key) announce an honest
    /// failure and do NOT retry the dangerous command.
    private func handleKeyInstallAck(status: UInt8) {
        guard let driver, let key = pendingInstallKey else { return }
        guard status == 0x00 else {
            announceNeedsPairing(reason: .installFailed("the ring did not accept the key (status \(status))"))
            return
        }
        // Persist ONLY on OK, so a failed/absent ack never leaves a wrongly-trusted key behind.
        guard OuraKeyStore.save(key, deviceId: deviceId) else {
            announceNeedsPairing(reason: .installFailed("the installed key could not be stored"))
            return
        }
        log("Oura: key installed and stored - re-running auth with the new key")
        pendingInstallKey = nil
        // Re-auth with the freshly-installed key. The driver returns enable-notify + get-nonce; the nonce
        // response then flows through the normal handleSecure -> advance path to streaming.
        write(driver.keyInstallAcknowledged())
    }

    /// A fresh 16-byte application key for the adopt install, from the system CSPRNG. Per OURA_PROTOCOL.md
    /// s3 the key is exactly 16 bytes; `SecRandomCopyBytes` is the same CSPRNG the rest of the app relies on.
    /// Returns nil if the RNG fails (then the caller stays honest rather than installing a weak key).
    private static func randomInstallKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: OuraKeyStore.keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    // MARK: - Buffer / persistence

    private func enqueue(_ events: [OuraEvent], ts: Int) {
        guard !events.isEmpty else { return }
        buffer.append((events: events, ts: ts))
        if buffer.count >= flushCount || Date().timeIntervalSince(lastFlush) >= flushInterval {
            flush()
        }
    }

    private func flush() {
        guard feedsLive, !buffer.isEmpty else { lastFlush = Date(); return }
        for entry in buffer {
            // Pure, unit-tested mapping (events -> Streams) keyed by each entry's own ts (wall-clock for
            // live pushes, ring-time-anchored for history-fetched records). A signal that could not be
            // decoded never reaches here, so a missing stream stays empty, never faked.
            persist(OuraStreamMapping.streams(from: entry.events, at: entry.ts))
        }
        buffer.removeAll()
        lastFlush = Date()
    }

    /// Flush every event parked in `pendingAnchorEvents`, now that `driver.unixSeconds` can resolve them
    /// (called right after the anchor is set) - OR, if called at session teardown with NO anchor ever
    /// having arrived, with an honest wall-clock fallback (a rough stamp beats silently dropping real
    /// decoded samples). Reset the buffer afterward so nothing is drained twice.
    private func drainPendingAnchorEvents() {
        guard !pendingAnchorEvents.isEmpty, let driver else { return }
        let now = Int(Date().timeIntervalSince1970)
        for pending in pendingAnchorEvents {
            let ts = driver.unixSeconds(forRingTimestamp: pending.ringTimestamp) ?? now
            enqueue([pending.event], ts: ts)
        }
        pendingAnchorEvents.removeAll()
    }

    // MARK: - Live ingest

    /// Fold decoded events into live state (HR / R-R only - skin temp and SpO2 are SLEEP-ONLY on this
    /// hardware, never a live readout) + the persist buffer. Live-push events (HR/IBI/battery) are stamped
    /// at wall-clock arrival time, since they genuinely are "now". History-fetched events (temp, SpO2, HRV,
    /// sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) so last night's data is never
    /// mis-recorded as happening right now; when no anchor has arrived yet this session, we park the event
    /// until one does (`pendingAnchorEvents`), rather than immediately guessing wall-clock. Out-of-range
    /// HR/temp is dropped, never shown.
    private func ingest(_ events: [OuraEvent]) {
        guard !events.isEmpty, let driver else { return }
        let now = Int(Date().timeIntervalSince1970)
        for e in events {
            switch e {
            case .hr(let hr):
                guard hr.bpm >= 30, hr.bpm <= 220 else { continue }   // physiological gate
                if !loggedFirstHR {
                    loggedFirstHR = true
                    log("Oura: receiving live data - first HR \(hr.bpm) bpm")
                }
                if feedsLive {
                    live.heartRate = hr.bpm
                    live.connected = true
                }
                enqueue([e], ts: now)

            case .ibi(let ibi):
                if feedsLive { live.setRRIntervals([ibi.ibiMs]) }
                enqueue([e], ts: now)

            case .battery(let bat):
                batteryPct = bat.percent
                onBattery(bat.percent)
                log("Oura: battery \(bat.percent)%")
                enqueue([e], ts: now)

            case .temp(let t):
                guard t.celsius >= 20, t.celsius <= 45 else { continue }   // physiological gate (wrist skin temp)
                if !loggedFirstTemp {
                    loggedFirstTemp = true
                    log("Oura: first skin temp decoded (last night) - \(String(format: "%.2f", t.celsius))C")
                }
                if let ts = driver.unixSeconds(forRingTimestamp: t.ringTimestamp) {
                    enqueue([e], ts: ts)
                } else {
                    pendingAnchorEvents.append((e, t.ringTimestamp))
                }

            case .spo2(let s):
                if !loggedFirstSpo2 {
                    loggedFirstSpo2 = true
                    log("Oura: first SpO2 decoded (last night) - value \(s.value) (\(s.unit))")
                }
                if let ts = driver.unixSeconds(forRingTimestamp: s.ringTimestamp) {
                    enqueue([e], ts: ts)
                } else {
                    pendingAnchorEvents.append((e, s.ringTimestamp))
                }

            case .hrv(let v):
                if let ts = driver.unixSeconds(forRingTimestamp: v.ringTimestamp) {
                    enqueue([e], ts: ts)
                } else {
                    pendingAnchorEvents.append((e, v.ringTimestamp))
                }

            case .sleepPhase(let v):
                if let ts = driver.unixSeconds(forRingTimestamp: v.ringTimestamp) {
                    enqueue([e], ts: ts)
                } else {
                    pendingAnchorEvents.append((e, v.ringTimestamp))
                }

            case .timeSync:
                if !loggedAnchor {
                    loggedAnchor = true
                    log("Oura: UTC time anchor acquired - history-fetched samples now get their real time")
                }
                // The 0x42 time-sync can arrive ANYWHERE in a history-fetch stream, not necessarily first.
                // Anything parked while unanchored gets its real time retroactively the moment an anchor lands.
                drainPendingAnchorEvents()

            case .tierB(let summary):
                // INVESTIGATION ONLY (real_steps / activity-summary / sleep-summary / smoothed-SpO2,
                // OURA_PROTOCOL.md s7.3 Tier B; PR #960). Logged ONCE PER KIND with the raw bytes so we
                // can see whether the ring sends these tags at all and collect capture material - e.g.
                // real_steps 0x7E/0x7F is server-flag-gated OFF by default ([open_oura-feat]), so its
                // continued absence here is the ring's doing, not a decode gap. Never persisted, never
                // scored (OuraStreamMapping drops .tierB unconditionally regardless of this log).
                if !loggedTierBKinds.contains(summary.kind) {
                    loggedTierBKinds.insert(summary.kind)
                    let hex = summary.rawPayload.map { String(format: "%02x", $0) }.joined(separator: " ")
                    log("Oura: Tier-B \(summary.kind) seen (tag 0x\(String(summary.tag, radix: 16))) - raw: \(hex)")
                }

            case .activityInfo(let info):
                // INVESTIGATION ONLY (0x50 activity/MET, Tier B - a plausible third-party formula, NOT
                // ground-truth-validated; see OuraActivityInfo). Logged with the DECODED state/MET values
                // every time (not once-per-kind): this is the tag under active plausibility evaluation, so
                // every real capture is evidence. Never persisted, never scored, and NEVER converted into
                // steps (MET is not a step count; OuraStreamMapping drops .activityInfo unconditionally).
                log("Oura: activity (Tier-B) state=\(info.state) met=\(info.met)")

            default:
                break   // motion / state / rtcBeacon / debugText: not a durable Streams row (see OuraStreamMapping)
            }
        }
    }

    // MARK: - Re-engagement timer (daytime-HR auto-reverts ~20s)

    private func startReengageTimer() {
        stopReengageTimer()
        let t = Timer.scheduledTimer(withTimeInterval: reengageInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reengageLiveHR() }
        }
        reengageTimer = t
    }

    private func stopReengageTimer() {
        reengageTimer?.invalidate()
        reengageTimer = nil
    }

    /// Re-send the live-HR enable+subscribe so the ~20 s auto-revert never silently stops the stream.
    private func reengageLiveHR() {
        guard let driver, reachedStreaming else { return }
        write(driver.reengageLiveHRCommands())
    }

    // MARK: - Honest needs-pairing fallback (Huami precedent)

    private enum NeedsPairingReason {
        case factoryResetOrNoKey
        case authFailed(OuraAuthStatus)
        case installFailed(String)
    }

    /// Record + log the honest "this ring needs a pairing handshake NOOP can't complete" outcome (once),
    /// and drop the link so no half-authenticated session lingers. We never fabricate a reading. Also marks
    /// `adoptPhase = .failed` so an in-flight adopt's Adopting step lands on a REACHABLE honest Failed state
    /// (file-import + Advanced-key fallbacks), and clears any in-flight install key WITHOUT persisting it (a
    /// failed install must never leave a wrongly-trusted key). RECOVERY-HONEST: a factory-reset ring is NOT
    /// bricked; re-pairing it in the Oura app brings it back. We never claim a key was installed here.
    private func announceNeedsPairing(reason: NeedsPairingReason) {
        // A failed install must drop its pending key whether or not this is the first announce.
        pendingInstallKey = nil
        adoptPhase = .failed
        // This is an honest dead-end (no key / auth rejected / install failed), NOT a transient drop, so the
        // ensuing disconnect must NOT auto-reconnect (that would loop the same auth failure and drain the
        // ring). Suppress it the same way a deliberate teardown does (#912): a later user reconnect re-arms.
        // Run this UNCONDITIONALLY, before the first-announce guard, so a SECOND announce in the same session
        // (needsPairing already set) still cancels the lingering peripheral and re-suppresses the reconnect,
        // mirroring the Android twin (OuraLiveSource.kt announceNeedsPairing).
        intentionalDisconnect = true
        reconnectID = nil
        failedReconnectAttempts = 0
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        guard needsPairing == nil else { return }
        let detail: String
        switch reason {
        case .factoryResetOrNoKey:
            detail = "NOOP needs the ring's install key to read it live, and that pairing handshake isn't set up yet."
        case .authFailed(let status):
            detail = "The ring rejected the pairing handshake (status \(status.rawValue))."
        case .installFailed(let why):
            detail = "NOOP couldn't take over this ring (\(why))."
        }
        let recovery = " The ring isn't bricked: re-pair it in the Oura app to recover it."
        let msg = detail + " Live data isn't available - export from the Oura app and import the file instead." + recovery
        needsPairing = msg
        log("Oura: \(msg)")
        stopReengageTimer()
        stopHistoryFetchTimer()
        if feedsLive { live.connected = false; live.streamingLiveHR = false }
    }

    // CB delegate callbacks live in the @preconcurrency extensions below. The queue-less central delivers
    // them on the main thread, so MainActor isolation is sound; @preconcurrency lets this @MainActor type
    // satisfy the nonisolated CoreBluetooth requirements (same pattern as StandardHRSource / BLEManager).
}

// MARK: - CBCentralManagerDelegate

extension OuraLiveSource: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Replay any intent that arrived before the radio was ready.
            if let id = pendingConnectID, let p = seenPeripherals[id] {
                pendingConnectID = nil
                central.connect(p, options: nil)
            } else if scanning {
                central.scanForPeripherals(withServices: [Self.service],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        default:
            // Radio off / unauthorized / resetting -> the link is not live.
            if feedsLive { live.connected = false; live.streamingLiveHR = false }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        // The scan already filters on the Oura service, but re-check the name through the gen recogniser
        // so a coincidental service match without an Oura-shaped name is dropped (best-effort).
        let detectedGen = OuraRingGen.recognise(advertisedName: name)
        let id = peripheral.identifier
        let firstSight = seenPeripherals[id] == nil
        seenPeripherals[id] = peripheral
        if firstSight { log("Oura: found \(name.isEmpty ? "Oura ring" : name) (\(id)) rssi \(RSSI.intValue)") }
        let ring = DiscoveredRing(id: id,
                                  name: name.isEmpty ? "Oura" : name,
                                  rssi: RSSI.intValue,
                                  detectedGen: detectedGen)
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx] = ring
        } else {
            discovered.append(ring)
        }
        // If we were scanning specifically to reach this ring (a not-yet-cached active ring), connect now.
        if pendingConnectID == id {
            pendingConnectID = nil
            connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Oura: connected - discovering services")
        failedReconnectAttempts = 0   // a real connection clears the reconnect backoff (#912)
        peripheral.delegate = self
        // Fresh driver per connection so a new session re-runs auth (the app key is session-scoped). The
        // driver's `allowKeyInstall` is gated on this connection's adopt consent ONLY: with no consent the
        // dangerous `0x24` installKey can never be sequenced, so a read-only / Advanced-key connect stays
        // honest (it announces needs-pairing instead of provisioning). Per OURA_PROTOCOL.md s3.2.
        // allowTierB: true - INVESTIGATION ONLY (activity/real_steps/sleep-summary/smoothed-SpO2 tags,
        // OURA_PROTOCOL.md s7.3 Tier B, UNVERIFIED layouts; PR #960). This lets `ingest` LOG what the
        // ring actually sends (raw bytes per kind, decoded MET for 0x50) so the layouts can be validated
        // against real captures. It can never leak a value into scoring: OuraStreamMapping drops
        // .tierB/.activityInfo unconditionally - the Tier-discipline gate that matters lives there, not here.
        driver = OuraDriver(ringGen: ringGen,
                            authKey: authKey().map { [UInt8]($0) },
                            allowTierB: true,
                            allowKeyInstall: adoptIntent)
        reachedStreaming = false
        loggedFirstHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        pendingAnchorEvents.removeAll()   // a fresh session must never replay a stale-anchor guess
        pendingInstallKey = nil
        adoptPhase = .idle
        reassembler.reset()
        // Resume the GetEvents cursor from where the LAST connection to this ring left off (s5.1/5.3), so
        // a routine reconnect doesn't re-fetch the ring's entire banked history every time.
        historyCursor = OuraHistoryCursorStore.read(deviceId: deviceId)
        peripheral.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Oura: WARNING failed to connect - \(error?.localizedDescription ?? "unknown error")")
        if feedsLive { live.connected = false; live.streamingLiveHR = false }
        // The ring wiped its bond (re-paired in the Oura app, or a firmware reset). CoreBluetooth surfaces
        // this as a stable CBError, and re-issuing connect just loops the same stale-pairing failure and
        // drains the ring, so DON'T auto-reconnect: route to the honest needs-pairing path instead, exactly
        // like BLEManager returns early on this error without rescheduling (#912/#414).
        if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
            announceNeedsPairing(reason: .factoryResetOrNoKey)
            return
        }
        // A failed connect to the paired ring (e.g. out of range at launch) retries on the backoff so the
        // ring comes back on its own, mirroring BLEManager's failed-connect reschedule (#912/#414).
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            log("Oura: disconnected - \(error.localizedDescription)")
        } else {
            log("Oura: disconnected (clean)")
        }
        stopReengageTimer()
        stopHistoryFetchTimer()
        // Drain BEFORE driver.stop() clears its anchor (same reasoning as stop()).
        drainPendingAnchorEvents()
        driver?.stop()
        driver = nil
        reassembler.reset()
        writeCharacteristic = nil
        loggedFirstHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        reachedStreaming = false
        pendingInstallKey = nil
        // A disconnect MID-install is an honest failure (no ack came); a disconnect after streaming leaves
        // the completed `.streaming` outcome intact so the wizard's success transition isn't undone.
        if adoptPhase == .installingKey { adoptPhase = .failed }
        batteryPct = nil
        flush()
        if feedsLive { live.connected = false; live.streamingLiveHR = false }
        if self.peripheral?.identifier == peripheral.identifier { self.peripheral = nil }
        // Auto-reconnect on an INVOLUNTARY drop (#912): the paired ring went out of range or the link timed
        // out. Re-issue a connect on the backoff so it comes back on its own, exactly like the WHOOP strap.
        // A deliberate `stop()` set `intentionalDisconnect`/cleared `reconnectID`, so this is a no-op there.
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension OuraLiveSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Oura: WARNING service discovery failed - \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            log("Oura: services discovered but the list was empty")
            return
        }
        guard let svc = services.first(where: { $0.uuid == Self.service }) else {
            log("Oura: Oura service NOT FOUND - this ring may not expose the expected GATT layout")
            return
        }
        log("Oura: Oura service found - discovering characteristics")
        // Discover the write + notify chars (gen5 also advertises ...0004/5/6, which v1 discovers but
        // never writes to). RingGen drives which to discover.
        let charUUIDs = OuraGatt.characteristicUUIDs(for: ringGen).map { CBUUID(string: $0) }
        peripheral.discoverCharacteristics(charUUIDs, for: svc)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("Oura: WARNING characteristic discovery failed - \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else {
            log("Oura: characteristics discovered but the list was empty")
            return
        }
        if let wc = chars.first(where: { $0.uuid == Self.writeChar }) {
            writeCharacteristic = wc
            log("Oura: write characteristic found")
        } else {
            log("Oura: write characteristic NOT FOUND - cannot drive the ring")
        }
        if let nc = chars.first(where: { $0.uuid == Self.notifyChar }) {
            log("Oura: notify characteristic found - enabling notifications")
            peripheral.setNotifyValue(true, for: nc)
        } else {
            log("Oura: notify characteristic NOT FOUND - cannot read the ring")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == Self.notifyChar else { return }
        if let error = error {
            log("Oura: WARNING enabling notifications FAILED - \(error.localizedDescription) - ring will send no data")
            return
        }
        log("Oura: notifications enabled (isNotifying=\(characteristic.isNotifying)) - beginning auth")
        // Notifications are live: tell the driver we're ready. It returns the auth-nonce request (or, with
        // no key, drives the honest needs-pairing path).
        advance(.ready)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value, characteristic.uuid == Self.notifyChar else { return }
        let bytes = [UInt8](value)
        // The notify char carries TWO framings on the same channel (OURA_PROTOCOL.md s2):
        //   - 0x2F secure-session sub-frames (auth nonce/status, enable ACKs, live-HR pushes)
        //   - inner TLV event records (IBI / HRV / SpO2 / temp / sleep-phase / battery)
        // Split the notification into outer frames; route 0x2F ones through the driver's secure handler,
        // and feed the remainder to the reassembler as TLV records.
        guard let driver else { return }
        let frames = OuraFraming.parseOuterFrames(bytes)
        // The `0x25` SetAuthKey-response is an OUTER frame (NOT a 0x2F secure sub-frame): `25 01 <status>`,
        // status `0x00` = OK (OURA_PROTOCOL.md s3.2). It only ever arrives during an adopt install we
        // initiated, so handle it ONLY while a key install is pending; otherwise it is ignored (never fed to
        // the TLV decoder, where its op byte would be misread as a record type). Per OURA_PROTOCOL.md s3.2.
        if pendingInstallKey != nil,
           let ackFrame = frames.first(where: { $0.op == Self.setAuthKeyRespOp }) {
            handleKeyInstallAck(status: ackFrame.body.first ?? 0xFF)
            return
        }
        // The `0x11` GetEvents summary drives the history-fetch cursor loop (s5.2/5.3) - detected here as a
        // side-channel PEEK, intentionally NOT stripped from `frames` below: its op (0x11) is well below the
        // event-tag range (tags are >= 0x41), so it round-trips safely through the TLV decoder as an
        // "unknown tag" no-op with correct byte accounting (both framings share the same op/len/body wire
        // shape, so the byte count consumed is identical either way).
        if let summaryFrame = frames.first(where: { $0.op == OuraFraming.getEventsResponseOp }) {
            let hex = summaryFrame.body.map { String(format: "%02x", $0) }.joined(separator: " ")
            log("Oura: GetEvents summary raw body (\(summaryFrame.body.count)B) - \(hex)")
            if let summary = OuraFraming.parseGetEventsResponse(summaryFrame.body) {
                handleHistorySummary(summary)
            }
        }
        // The `0x0D` GetBattery response is ALSO an outer frame (never a TLV record, s6.10), detected the
        // same non-destructive way as the 0x11 summary: its op is below the event-tag range (>= 0x41), so
        // it round-trips safely through the TLV decoder as an "unknown tag" no-op if left unfiltered. Routed
        // through the existing `.battery` ingest path (batteryPct/onBattery/log side effects).
        if let batteryFrame = frames.first(where: { $0.op == OuraFraming.batteryResponseOp }),
           let battery = OuraDecoders.decodeBattery(batteryFrame.body) {
            ingest([.battery(battery)])
        }
        if frames.contains(where: { $0.op == OuraFraming.secureSessionOp }) {
            for frame in frames where frame.op == OuraFraming.secureSessionOp {
                guard let secure = OuraFraming.parseSecureFrame(frame) else { continue }
                handleSecure(driver.handleSecureFrame(secure))
            }
            // Any non-secure outer frames in the same notification are TLV records; fall through to decode.
            // The 0x25 ack (if any) is consumed above, so it never reaches here.
            let tlvBytes = frames.filter { $0.op != OuraFraming.secureSessionOp && $0.op != Self.setAuthKeyRespOp }
                                 .flatMap { [$0.op, UInt8($0.body.count)] + $0.body }
            if !tlvBytes.isEmpty {
                ingest(driver.ingest(notification: tlvBytes, reassembler: reassembler))
            }
            return
        }
        // No secure frame in this notification: treat the whole value as TLV record bytes.
        ingest(driver.ingest(notification: bytes, reassembler: reassembler))
    }

    /// Act on what the driver resolved a 0x2F secure sub-frame to.
    private func handleSecure(_ routing: OuraDriver.SecureRouting) {
        switch routing {
        case .nonce(let nonce):
            log("Oura: auth nonce received - submitting proof")
            advance(.nonceReceived(nonce))
        case .authStatus(let status):
            if status.isSuccess {
                log("Oura: auth OK - enabling live HR")
            } else {
                log("Oura: WARNING auth status \(status.rawValue)")
            }
            advance(.authCompleted(status))
        case .enableAck:
            advance(.enableAckReceived)
        case .liveHRPush(let body):
            guard let driver else { return }
            ingest(driver.ingestLiveHRPush(body: body))
        case .unhandled:
            break
        }
    }
}

// MARK: - Oura install-key Keychain accessor

/// Keychain Services wrapper for the per-ring 16-byte Oura application install key. Mirrors the
/// `AIKeyStore` generic-password pattern (`Strand/AI/AICoach.swift`) so the key never lands in
/// UserDefaults, a plist, or on disk in the clear. The key is scoped per `deviceId` (the `account`), so
/// each registered ring has its own item. The install key is written here from exactly two places: the
/// adopt key-install handshake (on an OK `0x25` ack, `OuraLiveSource.handleKeyInstallAck`) and the wizard's
/// Advanced "I already have my ring's key" path. This accessor only stores/reads/clears it.
public enum OuraKeyStore {
    private static let service = "com.noop.oura.installkey"
    /// The fixed key length per OURA_PROTOCOL.md s3 (16-byte application auth key).
    public static let keyLength = 16

    private static func baseQuery(deviceId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
        ]
    }

    /// Store (or replace) the 16-byte install key for `deviceId`. A wrong-length key is rejected (no
    /// partial key is ever stored, so a later read can't return a malformed key).
    @discardableResult
    public static func save(_ key: Data, deviceId: String) -> Bool {
        guard key.count == keyLength else { return false }
        SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
        var attrs = baseQuery(deviceId: deviceId)
        attrs[kSecValueData as String] = key
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Read the stored 16-byte install key for `deviceId`, or nil if none is set (or the stored item is
    /// the wrong length, which is treated as absent so the honest needs-pairing path runs).
    public static func read(deviceId: String) -> Data? {
        var query = baseQuery(deviceId: deviceId)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == keyLength else { return nil }
        return data
    }

    /// Remove the stored install key for `deviceId`.
    public static func clear(deviceId: String) {
        SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
    }
}

// MARK: - Oura GetEvents cursor persistence

/// Persists the Oura `GetEvents` cursor (OURA_PROTOCOL.md s5.1/5.3) per ring, so a later connection
/// resumes from where the last session left off instead of re-fetching the ring's entire banked history
/// on every single connect. Unlike `OuraKeyStore` this is NOT sensitive - it's an opaque ring-clock tick
/// counter, not a credential - so plain `UserDefaults` is the right (and simplest) store.
enum OuraHistoryCursorStore {
    private static func key(deviceId: String) -> String { "com.noop.oura.historyCursor.\(deviceId)" }

    /// The persisted cursor for `deviceId`, or 0 (fetch everything) if none is stored yet.
    static func read(deviceId: String) -> UInt32 {
        let raw = UserDefaults.standard.object(forKey: key(deviceId: deviceId)) as? Int ?? 0
        return UInt32(clamping: raw)
    }

    /// Store the advanced cursor for `deviceId`.
    static func save(_ cursor: UInt32, deviceId: String) {
        UserDefaults.standard.set(Int(cursor), forKey: key(deviceId: deviceId))
    }
}
