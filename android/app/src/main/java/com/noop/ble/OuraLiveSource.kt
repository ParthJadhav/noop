package com.noop.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import com.noop.data.OuraStreamMapping
import com.noop.data.StreamBatch
import com.noop.data.StreamPersistence
import com.noop.oura.OuraAuth
import com.noop.oura.OuraCommand
import com.noop.oura.OuraDriver
import com.noop.oura.OuraDriverPhase
import com.noop.oura.OuraEvent
import com.noop.oura.OuraFraming
import com.noop.oura.OuraGatt
import com.noop.oura.OuraCommands
import com.noop.oura.OuraDecoders
import com.noop.oura.OuraOuterFrame
import com.noop.oura.OuraReassembler
import com.noop.oura.OuraRingGen
import com.noop.oura.OuraTransition
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * EXPERIMENTAL, ISOLATED live-BLE source for the Oura ring (gen3 / gen4 / gen5).
 *
 * Faithful Kotlin twin of Strand/BLE/OuraLiveSource.swift. This replaced an earlier honest dead-end
 * probe: where that probe only proved "there's no OPEN stream", this transport speaks the
 * ring's OWN documented protocol (clean-room, see docs/OURA_PROTOCOL.md) to authenticate with the
 * 16-byte application key, enable the daytime-HR feature, and decode the ring's RAW signals
 * (HR / IBI / RMSSD / SpO2 / skin-temp / sleep-phase tags). NOOP computes its OWN Charge/Rest from
 * those raw signals; the ring's encrypted readiness/sleep SCORES are never read or surfaced
 * (honest-data invariant).
 *
 * All BLE specifics live here; all protocol specifics live in the JVM-pure [OuraDriver] (which holds
 * NO BluetoothGatt). This class owns the transport and feeds the driver only bytes + transition events.
 *
 * WHOOP-FIRST ISOLATION (identical to [StandardHrSource] / [HuamiHrSource]): this class runs its OWN
 * scan + [BluetoothGatt] and never imports, calls, or shares state with the WHOOP BLE client. The
 * WHOOP path cannot regress because of anything here. The only shared surfaces are injected closures:
 *   - [liveSink]  pushes the ring's live HR (bpm) + R-R (ms) into whatever the UI observes (the
 *                 [SourceCoordinator] wires it to the same live state a WHOOP/strap reading uses).
 *   - [persist]   wired by the app to `repository.insert(StreamBatch, deviceId)` for the active ring.
 *   - [log]       the SAME exportable strap log (issue #421); every line is prefixed "Oura: ".
 *   - [onBattery] surfaces the ring's battery percent the same place a strap's does.
 *
 * HONEST FALLBACK (Huami precedent): when no install key is available ([authKey] returns null) or the
 * ring reports it is in factory reset, the ring needs a pairing/provisioning handshake the live flow
 * does not silently perform. This source then publishes an HONEST message via [needsPairing] and stays
 * disconnected from data - it NEVER fabricates a reading and never displays Oura's own scores.
 *
 * Android runtime-permission notes (same contract as the other sources): the caller must hold
 * BLUETOOTH_SCAN + BLUETOOTH_CONNECT before [scan]/[connect]. Every android.bluetooth call is
 * @SuppressLint("MissingPermission") - the caller owns the grant.
 */
@SuppressLint("MissingPermission")
class OuraLiveSource(
    context: Context,
    /** Datastore device id every sample is stamped with (the active ring's registry id). */
    private val deviceId: String,
    /** The ring generation (selected by the user in the wizard, recovered from the row model). Drives
     *  the MTU clamp, discovered-characteristic set, and the live-HR enable command set. */
    private val ringGen: OuraRingGen,
    /** Push live HR (bpm) + R-R (ms) into whatever the UI observes. Called on the main looper. Mirrors
     *  [StandardHrSource.liveSink] so the [SourceCoordinator] wires both the same way. */
    private val liveSink: (hr: Int, rr: List<Int>) -> Unit,
    /** Returns the 16-byte application auth key (unsigned bytes 0..255) for this ring, or null when none
     *  has been provisioned. INJECTED, never hardcoded (the key lives in [OuraInstallKeyStore], backed by
     *  the Android Keystore). null drives the honest [needsPairing] path - no faked data. */
    private val authKey: () -> IntArray?,
    /** Persist a batch under [deviceId] - wired to `repository.insert`. Mirrors the other sources. */
    private val persist: (StreamBatch, String) -> Unit = { _, _ -> },
    /** Diagnostic sink for the connect/auth/stream lifecycle - the SAME exportable strap log (#421).
     *  Every line is prefixed "Oura: ". Statuses / UUIDs / counts only, NEVER a device address. Default
     *  no-op keeps existing call sites compiling and tests silent. */
    private val log: (String) -> Unit = {},
    /** Fired with the ring's battery percent (0-100) when decoded. */
    private val onBattery: (Int) -> Unit = {},
    /**
     * Source of cryptographically-random bytes for a freshly-generated install key (adopt flow step 1).
     * Injected so a test can pin a deterministic key; production defaults to [java.security.SecureRandom]
     * (the platform CSPRNG) so a forgotten injection is still secure, never a predictable key. Returns null
     * on RNG failure (then provisioning stays honest rather than installing a weak key).
     */
    private val randomKey: () -> IntArray? = { secureRandom16() },
) {

    /**
     * The live outcome of an in-flight adopt (the wizard observes this to leave its Adopting step). Kotlin
     * twin of Swift's `OuraLiveSource.AdoptPhase`. Reset to [Idle] on every connect/stop/disconnect so a
     * stale outcome never drives a transition.
     */
    enum class AdoptPhase {
        /** No adopt in flight (the default; a read-only connect never leaves this until streaming). */
        Idle,

        /** The dangerous 0x24 install was written; awaiting the 0x25 ack (an install IS running). */
        InstallingKey,

        /** Auth (re-auth on the adopt path) succeeded and HR/IBI is streaming: adoption complete. */
        Streaming,

        /** An honest dead-end (no ack / ack != OK / re-auth failed / no key): never a fake success. */
        Failed,
    }

    /** An Oura ring seen during a scan (UI affordance). [detectedGen] is a best-effort generation guess
     *  from the advertised name (null when the name carries no generation marker); the wizard confirms it
     *  via the model the user picks. Mirrors the Swift DiscoveredRing.detectedGen. */
    data class DiscoveredRing(
        val address: String,
        val name: String,
        val rssi: Int,
        val detectedGen: OuraRingGen? = null,
    )

    private val _discovered = MutableStateFlow<List<DiscoveredRing>>(emptyList())
    /** Rings discovered during the current scan, keyed by address (newest RSSI wins). */
    val discovered: StateFlow<List<DiscoveredRing>> = _discovered.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    /** True while a scan is running. */
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _batteryPct = MutableStateFlow<Int?>(null)
    /** The connected ring's battery percent, 0-100, once decoded; null until then or after disconnect
     *  (a stale value must not outlive the link). Surfaced on the device card like the WHOOP battery. */
    val batteryPct: StateFlow<Int?> = _batteryPct.asStateFlow()

    private val _needsPairing = MutableStateFlow<String?>(null)
    /** Set to an HONEST explanation when the ring needs a key install / pairing the live flow can't do
     *  (no app key, or the ring is in factory reset). null otherwise; cleared on scan/connect/stop. The
     *  source stays at "-" while this is set - never a fabricated value. */
    val needsPairing: StateFlow<String?> = _needsPairing.asStateFlow()

    private val _adoptPhase = MutableStateFlow(AdoptPhase.Idle)
    /** The live adopt outcome (see [AdoptPhase]). The wizard observes this to leave its Adopting step. Reset
     *  to [AdoptPhase.Idle] on every connect/stop/disconnect so a stale outcome never drives a transition. */
    val adoptPhase: StateFlow<AdoptPhase> = _adoptPhase.asStateFlow()

    // MARK: - Adopt consent (gates the DANGEROUS post-factory-reset key install, OURA_PROTOCOL.md s3.2)

    /**
     * EXPLICIT user-granted adopt consent for the NEXT connection. Default FALSE. The dangerous `0x24`
     * install opcode may be sent ONLY when this is true (it is wired straight to the per-connection driver's
     * `allowKeyInstall` gate). The Advanced-key path and every read-only connect leave it false, so they
     * NEVER provision a key (they stay honest via [announceNeedsPairing] when no valid key authenticates).
     */
    private var adoptIntent: Boolean = false

    /**
     * The freshly-generated install key, held in memory ONLY between writing the `0x24` install and the
     * `0x25` ack. It is persisted to the keystore ONLY once the ring acks OK (see [handleKeyInstallAck]), so
     * a failed/absent ack never leaves a wrongly-trusted key the next session would authenticate against.
     * The key is never logged. Mirrors Swift's `pendingInstallKey`.
     */
    private var pendingInstallKey: IntArray? = null

    /**
     * Grant (or revoke) adopt consent for the NEXT connection. The wizard's destructive adopt path calls
     * this with true AFTER its irreversible-consent gate AND its second "Take over" confirm, BEFORE
     * connecting, so the fresh per-connection driver is built with `allowKeyInstall == true` and the
     * dangerous install can run for exactly that session. It takes effect on the next connect (the driver
     * is re-created per connection); a connection already mid-flight is not retro-granted. Default-false
     * everywhere else keeps the dangerous opcode unreachable. Kotlin twin of Swift's `setAdoptIntent`.
     */
    fun setAdoptIntent(intent: Boolean) {
        adoptIntent = intent
    }

    // MARK: - Android Bluetooth handles (OWN scanner + GATT, separate from WHOOP)

    private val appContext = context.applicationContext
    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter
    private val scanner: BluetoothLeScanner? get() = adapter?.bluetoothLeScanner

    private var gatt: BluetoothGatt? = null
    /** Peripherals seen in the current scan, retained by address so a chosen one survives to connect. */
    private val seen = ConcurrentHashMap<String, BluetoothDevice>()
    /** A device asked to connect before a scan result for it landed (connect-by-address path). */
    private var pendingConnectAddress: String? = null

    /** The device of the in-flight connection, remembered so a status-133 disconnect can retry it. */
    private var lastDevice: BluetoothDevice? = null
    /** Guards the single status-133 (Android GATT_ERROR) auto-retry; reset on a successful connect. */
    private var retried133 = false
    /** Logs the FIRST live-HR sample of a connection only; reset on stop/disconnect. */
    private var loggedFirstHr = false
    /**
     * True once the driver first reached Streaming this connection, so the one-shot streaming work
     * (adoptPhase, re-engage timer, history-fetch kick-off, battery request) runs exactly once and is NOT
     * re-run when the driver returns to Streaming after each history-fetch pass completes. Reset on
     * stop/disconnect. Kotlin twin of Swift's `reachedStreaming`.
     */
    private var reachedStreaming = false
    /** Logs the FIRST skin-temp sample DECODED THIS SESSION only (never every record); reset on
     *  stop/disconnect. These are last-night values from the history fetch, not live pushes, but we still
     *  only want one log line, not one per sample. Twin of [loggedFirstHr]. */
    private var loggedFirstTemp = false
    /** Logs the FIRST SpO2 sample decoded this session only. Twin of [loggedFirstTemp]. */
    private var loggedFirstSpo2 = false
    /** Logs the FIRST ring-time -> UTC anchor of this session only (s5.5); reset on stop/disconnect. */
    private var loggedAnchor = false
    /** Tier-B (UNVERIFIED) kinds ("activity" / "real_steps" / "sleep_summary" / "spo2_smoothed") already
     *  logged this session, so a repeated tag logs once per KIND, not once per record. INVESTIGATION
     *  ONLY (see the `allowTierB = true` comment at driver construction) - the log is how we collect raw
     *  captures to validate these layouts; nothing here ever persists or scores. Reset on stop/disconnect. */
    private val loggedTierBKinds = mutableSetOf<String>()

    // MARK: - Auto-reconnect (#912)

    /**
     * The paired ring's address we should keep re-reaching. Set by [connect]/[connectToDevice], cleared by
     * [stop]. While it is non-null an INVOLUNTARY drop (or a failed connect) re-issues a connect on a capped
     * backoff, so the ring comes back on its own once it's in range again, exactly like the WHOOP strap's
     * auto-reconnect. WHOOP has this loop; the non-WHOOP sources never did, so a dropped Oura ring stayed
     * down until a manual reconnect. This never touches the WHOOP path or its client.
     *
     * @Volatile: written from [connect]/[stop] (main) and read in [scheduleReconnect]'s posted block and
     * the GATT-delivery-thread disconnect handler, so it needs cross-thread visibility - matching the WHOOP
     * client's reconnect state.
     */
    @Volatile
    private var reconnectAddress: String? = null
    /**
     * True while a teardown was USER/COORDINATOR-initiated ([stop]), so the disconnect handler suppresses
     * the auto-reconnect (twin of the Swift `intentionalDisconnect` / the WHOOP client's flag). Cleared on
     * every [connect].
     *
     * @Volatile: read on the GATT-delivery thread (onConnectionStateChange) and written on main
     * ([connect]/[stop]/[announceNeedsPairing]), so it needs cross-thread visibility - same as the WHOOP client.
     */
    @Volatile
    private var intentionalDisconnect = false
    /**
     * Consecutive involuntary reconnect attempts, feeding the capped-exponential [ReconnectBackoff] (3, 6,
     * 12, 24, 48, 60s). Reset to 0 on a successful connect and on an explicit [connect] so a ring genuinely
     * out of range doesn't hammer BLE. Twin of the WHOOP client's `failedReconnectAttempts` (which is
     * `@Volatile` for exactly this reason: it's read/reset on the GATT-delivery thread and written on main).
     */
    @Volatile
    private var failedReconnectAttempts = 0

    /**
     * The pending auto-reconnect, held as a NAMED field (not an anonymous lambda) so [stop] can remove it
     * from the main-looper handler via [handler.removeCallbacks] - exactly like [reengageRunnable] /
     * [cancelReengage]. An anonymous `postDelayed` lambda would otherwise be retained by the handler for the
     * full backoff (up to 60s) after a teardown. It reads the CURRENT [reconnectAddress]: a [stop] nulls
     * that (and sets [intentionalDisconnect]) so a firing runnable bails, and a fresh [connect] repoints it.
     */
    private val reconnectRunnable = Runnable {
        val address = reconnectAddress
        if (!intentionalDisconnect && address != null) connect(address)
    }

    /**
     * The one-shot status-133 retry, held as a NAMED field (like [reconnectRunnable]) so [stop] can remove
     * it from the handler rather than letting an anonymous lambda linger for its 1s window after a teardown.
     * Reads the CURRENT [lastDevice] at fire time (the newest connect target is the right one to retry).
     */
    private val retry133Runnable = Runnable {
        val device = lastDevice
        if (!intentionalDisconnect && device != null) connectToDevice(device)
    }

    /**
     * Schedule an auto-reconnect to the paired ring after a backoff delay, unless the teardown was
     * intentional or there is no known ring. Guarded again inside [reconnectRunnable]: a [stop] that lands
     * in the meantime removes the callback AND nulls the target/sets the flag, so a deliberate teardown
     * never races a stale reconnect. Re-posts the SAME named runnable (removing any prior one first) so at
     * most one reconnect is ever pending.
     */
    private fun scheduleReconnect() {
        if (intentionalDisconnect) return
        if (reconnectAddress == null) return
        failedReconnectAttempts += 1
        val delay = ReconnectBackoff.nextDelayMs(failedReconnectAttempts)
        log("Oura: reconnecting in ${delay / 1000}s (attempt $failedReconnectAttempts)")
        handler.removeCallbacks(reconnectRunnable)
        handler.postDelayed(reconnectRunnable, delay)
    }

    /** All BLE work hops onto the main looper, matching the other sources + CBCentralManager(queue:.main). */
    private val handler = Handler(Looper.getMainLooper())

    // MARK: - Protocol state (the pure driver + reassembler own all protocol logic)

    /**
     * The transport-agnostic protocol state machine. Recreated on each connect with a fresh snapshot of
     * the app key so a key provisioned mid-session is picked up on the next connect, and so a Stopped
     * driver never lingers. JVM-pure: holds NO BluetoothGatt.
     */
    private var driver: OuraDriver? = null

    /** Reassembles BLE notification fragments into complete TLV records (s2.4). Reset on disconnect so a
     *  half-record never bleeds into the next session. */
    private val reassembler = OuraReassembler()

    /** Cached characteristics, resolved in onServicesDiscovered. */
    private var writeChar: BluetoothGattCharacteristic? = null
    private var notifyChar: BluetoothGattCharacteristic? = null

    /** Periodic live-HR re-engage: daytime HR auto-reverts after ~20 s, so while streaming we re-send the
     *  enable+subscribe every ~15 s (OURA_PROTOCOL.md s5.7). The token lets stop() cancel it. */
    private var reengageScheduled = false
    private val reengageIntervalMs = 15_000L
    private val reengageRunnable = object : Runnable {
        override fun run() {
            val d = driver ?: return
            if (d.phase == OuraDriverPhase.Streaming) {
                for (cmd in d.reengageLiveHRCommands()) write(cmd)
            }
            // Reschedule only while a session is live; stop() clears reengageScheduled + removes callbacks.
            if (reengageScheduled) handler.postDelayed(this, reengageIntervalMs)
        }
    }

    // MARK: - History fetch (GetEvents, s5) - the ONLY path skin temp / SpO2 / HRV / sleep-phase ever
    // arrive by. Neither temp nor SpO2 is ever pushed live on this hardware; both are banked overnight and
    // retrievable only by asking the ring for its history. Kotlin twin of the Swift lane9 history wiring.

    /**
     * The GetEvents cursor to resume from, loaded from [OuraHistoryCursorStore] on connect and advanced as
     * `0x11` summaries arrive. 0 = fetch everything the ring has banked (first-ever connect for this ring;
     * OURA_PROTOCOL.md s5.1). Held as a Long (the unsigned 32-bit ring timestamp).
     */
    private var historyCursor: Long = 0

    /**
     * Periodic re-fetch while connected, so an overnight-connected session (or one left open after a nap)
     * picks up freshly-banked sleep data without needing a reconnect. Mirrors the WHOOP ~15 min periodic
     * history-offload floor. Held as a NAMED runnable so [stop]/disconnect can remove it from the handler,
     * matching [reengageRunnable] / [reconnectRunnable].
     */
    private var historyFetchScheduled = false
    private val historyFetchIntervalMs = 900_000L
    private val historyFetchRunnable = object : Runnable {
        override fun run() {
            fetchHistoryIfIdle()
            // Reschedule only while a session is live; stop()/disconnect clears the flag + removes callbacks.
            if (historyFetchScheduled) handler.postDelayed(this, historyFetchIntervalMs)
        }
    }

    /**
     * History-fetched events decoded BEFORE a ring-time -> UTC anchor exists this session, held here (with
     * their own ring timestamp) until the anchor lands ([drainPendingAnchorEvents]), so they get their real
     * historical time instead of a premature wall-clock guess. The ring's 0x42 time-sync can arrive
     * anywhere in a history-fetch stream, not necessarily first, so records that land before it are parked
     * here and re-stamped the moment an anchor lands. Drained with an honest wall-clock fallback at teardown
     * if no anchor ever arrived this session (never silently dropped). Reset on stop/disconnect. Kotlin twin
     * of Swift's `pendingAnchorEvents`.
     */
    private val pendingAnchorEvents = ArrayList<Pair<OuraEvent, Long>>()

    /**
     * Kick a history-fetch pass at the current cursor, but ONLY when the driver is idle-streaming (never
     * overlaps a fetch already in flight - the driver's own phase is the guard, so this is safe to call
     * both right after reaching Streaming and from the periodic timer). Kotlin twin of Swift's
     * `fetchHistoryIfIdle`.
     */
    private fun fetchHistoryIfIdle(): Unit = guardedCallback("history-fetch") {
        val d = driver ?: return@guardedCallback
        if (d.phase != OuraDriverPhase.Streaming) return@guardedCallback
        log("Oura: fetching history from cursor $historyCursor")
        advance(OuraTransition.StartHistoryFetch(cursor = historyCursor))
    }

    private fun scheduleHistoryFetch() {
        if (historyFetchScheduled) return
        historyFetchScheduled = true
        handler.postDelayed(historyFetchRunnable, historyFetchIntervalMs)
    }

    private fun cancelHistoryFetch() {
        historyFetchScheduled = false
        handler.removeCallbacks(historyFetchRunnable)
    }

    /**
     * Handle a `0x11` GetEvents response (OURA_PROTOCOL.md s5.2): persist the advanced cursor (so a LATER
     * connection resumes rather than re-fetching everything) and drive the driver's cursor-loop state
     * machine, which asks for another ack-fetch while `moreData` or returns to Streaming once caught up.
     *
     * The ring's terminal "no more data" response (moreData=false, status 0x00) zero-fills the cursor
     * field, whereas a mid-fetch response (moreData=true) carries a real advancing nonzero cursor. So the
     * cursor is only trusted/persisted while the response is actually carrying new data - persisting the
     * terminal zero would reset the cursor to 0 on every fetch and force a full backlog re-fetch forever.
     *
     * A cursor persisted from one BLE connection can come back SMALLER on the next connection's first real
     * cursor: `ringTimestamp = (session << 16) | counter` (s2.3), and the ring's internal `session`
     * component can shift across reconnects/restarts. Resuming from a cursor whose session no longer matches
     * the ring's current one is not a real resume - the ring just re-dumps its whole backlog anyway - so we
     * detect the regression and reset to an honest, explicit 0 rather than feed the ring a now-meaningless
     * reference. Kotlin twin of Swift's `handleHistorySummary`.
     */
    private fun handleHistorySummary(summary: com.noop.oura.GetEventsSummary): Unit = guardedCallback("history-summary") {
        if (summary.moreData) {
            if (summary.cursor < historyCursor) {
                log("Oura: ring-time regression detected (fetch cursor ${summary.cursor} < persisted " +
                    "$historyCursor) - the ring's session likely reset; resetting our cursor to 0")
                historyCursor = 0
                OuraHistoryCursorStore.save(appContext, deviceId, 0)
            } else {
                historyCursor = summary.cursor
                OuraHistoryCursorStore.save(appContext, deviceId, summary.cursor)
            }
        } else {
            log("Oura: history fetch caught up (cursor $historyCursor)")
        }
        advance(OuraTransition.HistoryCursorAdvanced(cursor = summary.cursor, moreData = summary.moreData))
    }

    // MARK: - Sample buffer (flushed in batches off the per-notification hot loop)

    /**
     * One buffered batch of decoded events, stamped with its own [ts] (unix seconds): live-push events
     * (HR, IBI, battery) are stamped at wall-clock arrival time; history-fetched events (temp, SpO2, HRV,
     * sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) when an anchor is available,
     * so last night's data is never mis-recorded as happening right now. Mirrors the Swift buffer
     * `(events, ts)`. [flush] folds each batch through the unit-tested [OuraStreamMapping] so the SAME pure
     * mapping the tests pin is the production path.
     */
    private data class Batch(val events: List<OuraEvent>, val ts: Int)

    private val bufferLock = Any()
    private val buffer = ArrayList<Batch>()
    private var lastFlushMs = System.currentTimeMillis()
    private val flushCount = 30
    private val flushIntervalMs = 30_000L

    // MARK: - Scanning

    /** Begin scanning for Oura rings advertising the ring's base service. */
    fun scan() {
        seen.clear()
        _discovered.value = emptyList()
        _scanning.value = true
        _needsPairing.value = null
        log("Oura: scanning for an Oura ring (${ringGen.displayName})…")
        val sc = scanner ?: run {
            _scanning.value = false
            log("Oura: no BLE scanner available - Bluetooth may be off or unsupported")
            return
        }
        if (adapter?.isEnabled != true) {
            _scanning.value = false
            log("Oura: Bluetooth adapter is off - cannot scan")
            return
        }
        // Filter by the ring's base service so a broad scan does not surface unrelated peripherals; the
        // callback further confirms the advertised name reads as an Oura ring.
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        sc.startScan(listOf(filter), settings, scanCallback)
    }

    /** Stop an in-progress scan. Idempotent. */
    fun stopScan() {
        _scanning.value = false
        if (adapter?.isEnabled == true) runCatching { scanner?.stopScan(scanCallback) }
    }

    // MARK: - Connecting

    /** Connect to the chosen discovered ring (by address) and start the auth → enable → stream flow. */
    fun connect(address: String) {
        stopScan()
        _needsPairing.value = null
        // Remember the paired ring so an involuntary drop auto-reconnects to it (#912). An explicit connect
        // is never the intentional-teardown case, so clear the suppression flag.
        reconnectAddress = address
        intentionalDisconnect = false
        val device = seen[address] ?: runCatching { adapter?.getRemoteDevice(address) }.getOrNull()
        if (device == null) { pendingConnectAddress = address; return }
        connectToDevice(device)
    }

    private fun connectToDevice(device: BluetoothDevice) {
        lastDevice = device   // remembered so a status-133 disconnect can auto-retry the same ring
        log("Oura: connecting to ${device.address}")
        // Tear down any prior link first so we never run two GATTs for this source.
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        // A fresh driver per connection: the app key is session-scoped (the proof handshake re-runs on
        // every connection), and a key provisioned since the last attempt is picked up here. allowKeyInstall
        // is wired straight from the connection's adoptIntent so the dangerous 0x24 write is reachable ONLY
        // under an explicit adopt consent (OURA_PROTOCOL.md s3.2).
        // allowTierB = true - INVESTIGATION ONLY (activity/real_steps/sleep-summary/smoothed-SpO2 tags,
        // OURA_PROTOCOL.md s7.3 Tier B, UNVERIFIED layouts; PR #960). This lets `emit` LOG what the ring
        // actually sends (raw bytes per kind, decoded MET for 0x50) so the layouts can be validated
        // against real captures. It can never leak a value into scoring: OuraStreamMapping drops
        // TierB/ActivityInfo unconditionally - the Tier-discipline gate that matters lives there, not here.
        driver = OuraDriver(ringGen = ringGen, authKey = authKey(), allowTierB = true,
                            allowKeyInstall = adoptIntent)
        reassembler.reset()
        pendingInstallKey = null       // a new connection starts with no install in flight
        _adoptPhase.value = AdoptPhase.Idle   // a stale outcome must never drive the wizard's transition
        // A fresh session: reset the one-shot streaming/anchor state, and never replay a stale-anchor guess.
        reachedStreaming = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.clear()
        pendingAnchorEvents.clear()
        // Resume the GetEvents cursor from where the LAST connection to this ring left off (s5.1/5.3), so a
        // routine reconnect doesn't re-fetch the ring's entire banked history every time.
        historyCursor = OuraHistoryCursorStore.read(appContext, deviceId)
        // connectGatt can throw (SecurityException if BLUETOOTH_CONNECT was revoked mid-session,
        // IllegalArgumentException on a stale device) - never let that crash the app; a failed start
        // simply leaves the previous source in place (mirrors [StandardHrSource]).
        gatt = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appContext, false, gattCallback)
            }
        }.getOrElse {
            log("Oura: connectGatt failed (${it.javaClass.simpleName}: ${it.message})")
            null
        }
    }

    /** Tear down: cancel the connection and stop scanning, persisting anything still buffered. Idempotent. */
    fun stop() {
        // A deliberate teardown (device switch / removal) must NOT auto-reconnect: mark it intentional and
        // drop the reconnect target so any pending backoff bails and no fresh one is scheduled (#912). Remove
        // any already-posted reconnect from the main-looper handler too, so it isn't retained for the full
        // backoff (mirrors cancelReengage's removeCallbacks).
        intentionalDisconnect = true
        reconnectAddress = null
        failedReconnectAttempts = 0
        handler.removeCallbacks(reconnectRunnable)
        handler.removeCallbacks(retry133Runnable)
        stopScan()
        pendingConnectAddress = null
        cancelReengage()
        cancelHistoryFetch()
        // Drain BEFORE driver.stop() clears its anchor, so a pending event still gets a real anchored time
        // if one exists rather than always falling back to wall-clock at teardown (mirrors Swift's stop()).
        drainPendingAnchorEvents()
        driver?.stop()
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = null
        writeChar = null
        notifyChar = null
        reassembler.reset()
        loggedFirstHr = false      // a later reconnect should log its first sample again
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.clear()
        reachedStreaming = false
        // A stop MID-install is an honest failure (no ack will come); a stop after streaming leaves the
        // completed Streaming outcome intact so the wizard's success transition is not undone.
        if (_adoptPhase.value == AdoptPhase.InstallingKey) _adoptPhase.value = AdoptPhase.Failed
        pendingInstallKey = null
        _batteryPct.value = null   // a stale charge must not outlive the link
        flush()
    }

    // MARK: - Buffer / persistence

    /** Buffer one batch of decoded events under the supplied [ts] (unix seconds: wall-clock for live
     *  pushes, ring-time-anchored for history-fetched records), flushing on count/interval. Mirrors the
     *  Swift `enqueue(_ events:ts:)`. */
    private fun enqueue(events: List<OuraEvent>, ts: Int) {
        if (events.isEmpty()) return
        val shouldFlush = synchronized(bufferLock) {
            buffer.add(Batch(events, ts))
            buffer.size >= flushCount ||
                System.currentTimeMillis() - lastFlushMs >= flushIntervalMs
        }
        if (shouldFlush) flush()
    }

    private fun flush() {
        val snapshot: List<Batch>
        synchronized(bufferLock) {
            lastFlushMs = System.currentTimeMillis()
            if (buffer.isEmpty()) return
            snapshot = ArrayList(buffer); buffer.clear()
        }
        // PRODUCTION PATH THROUGH THE TESTED MAPPING: fold each batch's raw events into a protocol Streams
        // via the unit-tested [OuraStreamMapping] (its Tier-B-drop + honest-data invariants), then widen to
        // the Room StreamBatch via [StreamPersistence.toBatch]. Each batch carries its OWN resolved ts
        // (wall-clock for live pushes; the ring-time-anchored UTC (s5.5) for history-fetched records), so
        // the mapping's per-batch constant anchor `{ batch.ts }` matches the Swift twin's
        // `OuraStreamMapping.streams(from: entry.events, at: entry.ts)`. Routing through the mapping (not
        // hand-built rows) is what keeps the production persist parity with Swift and under test.
        for (batch in snapshot) {
            val streams = OuraStreamMapping.streams(batch.events) { batch.ts }
            val out = StreamPersistence.toBatch(streams)
            if (out.hr.isNotEmpty() || out.rr.isNotEmpty() || out.spo2.isNotEmpty() ||
                out.skinTemp.isNotEmpty() || out.events.isNotEmpty() || out.battery.isNotEmpty()
            ) {
                persist(out, deviceId)
            }
        }
    }

    /**
     * Flush every event parked in [pendingAnchorEvents], now that `driver.unixSeconds` can resolve them
     * (called right after the anchor is set) - OR, if called at session teardown with NO anchor ever having
     * arrived, with an honest wall-clock fallback (a rough stamp beats silently dropping real decoded
     * samples). Reset the buffer afterward so nothing is drained twice. Kotlin twin of Swift's
     * `drainPendingAnchorEvents`.
     */
    private fun drainPendingAnchorEvents(): Unit = guardedCallback("drain-pending") {
        if (pendingAnchorEvents.isEmpty()) return@guardedCallback
        val d = driver ?: return@guardedCallback
        val now = (System.currentTimeMillis() / 1000L).toInt()
        for ((event, ringTimestamp) in pendingAnchorEvents) {
            val ts = d.unixSeconds(forRingTimestamp = ringTimestamp)?.toInt() ?: now
            enqueue(listOf(event), ts)
        }
        pendingAnchorEvents.clear()
    }

    // MARK: - Scan callback

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val address = device.address ?: return
            val name = result.scanRecord?.deviceName ?: runCatching { device.name }.getOrNull() ?: ""
            // Confirm the advertised name reads as an Oura ring (the service filter is the primary gate;
            // this rejects anything that slipped through advertising the same base service).
            if (ExperimentalBrand.recognise(name) != ExperimentalBrand.OURA) return
            val firstSight = seen.put(address, device) == null   // null → not seen before this scan
            if (firstSight) log("Oura: found $name ($address) rssi ${result.rssi}")
            // Best-effort generation guess from the advertised name (confirmed by the model the user picks).
            val detectedGen = OuraRingGen.recognise(name)
            val ring = DiscoveredRing(
                address = address,
                name = name.ifBlank { "Oura" },
                rssi = result.rssi,
                detectedGen = detectedGen,
            )
            val list = _discovered.value.toMutableList()
            val i = list.indexOfFirst { it.address == address }
            if (i >= 0) list[i] = ring else list.add(ring)
            _discovered.value = list
            // Replay a connect intent that arrived before the ring was discovered.
            if (pendingConnectAddress == address) {
                pendingConnectAddress = null
                handler.post { connectToDevice(device) }
            }
        }
    }

    // MARK: - GATT callback

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = guardedCallback("connection-state") {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        log("Oura: WARNING connected with non-success status=$status")
                    }
                    retried133 = false   // a real connection clears the one-shot 133 retry guard
                    failedReconnectAttempts = 0   // a real connection clears the reconnect backoff (#912)
                    log("Oura: connected (status=$status) - discovering services")
                    g.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    log("Oura: disconnected (status=$status)")
                    loggedFirstHr = false   // a reconnect should log its first sample again
                    _batteryPct.value = null
                    cancelReengage()
                    cancelHistoryFetch()
                    // Drain BEFORE the driver's anchor is gone (same reasoning as stop()): a pending event
                    // still gets a real anchored time if the current session set one, else an honest
                    // wall-clock fallback rather than being silently dropped.
                    drainPendingAnchorEvents()
                    reassembler.reset()
                    loggedFirstTemp = false
                    loggedFirstSpo2 = false
                    loggedAnchor = false
                    loggedTierBKinds.clear()
                    reachedStreaming = false
                    // A disconnect MID-install is an honest failure (no 0x25 ack will arrive); a disconnect
                    // after streaming leaves the completed Streaming outcome intact. Drop any in-flight key
                    // WITHOUT persisting it (a failed install must never leave a wrongly-trusted key).
                    if (_adoptPhase.value == AdoptPhase.InstallingKey) _adoptPhase.value = AdoptPhase.Failed
                    pendingInstallKey = null
                    flush()
                    if (gatt === g) { runCatching { g.close() }; gatt = null }
                    // Hardening: status 133 is Android's infamous generic GATT_ERROR on connect - almost
                    // always transient. Auto-retry ONCE (immediately, 1s) before falling through to the
                    // general capped-backoff auto-reconnect below.
                    if (status == GATT_ERROR_133 && !retried133 && lastDevice != null && !intentionalDisconnect) {
                        retried133 = true
                        log("Oura: connect error 133 - retrying once in 1s")
                        handler.postDelayed(retry133Runnable, 1000)
                        return@guardedCallback   // the one-shot 133 retry owns the reconnect for this drop
                    }
                    if (status == GATT_ERROR_133 && retried133) {
                        log("Oura: still failing (133) - try forgetting the ring in Android " +
                            "Settings → Bluetooth, then re-pair.")
                        // Fall through to the capped-backoff reconnect so a transient 133 storm still recovers
                        // on its own once the ring settles, rather than giving up until a manual reconnect.
                    }
                    // Auto-reconnect on an INVOLUNTARY drop / failed connect (#912): the paired ring went out
                    // of range or the link dropped. Re-issue a connect on the capped backoff so it comes back
                    // on its own, exactly like the WHOOP strap. A deliberate stop() set intentionalDisconnect
                    // and cleared reconnectAddress, so this is a no-op there; a needs-pairing dead-end also
                    // suppressed it. This owns its OWN scan/GATT and never touches the WHOOP path.
                    scheduleReconnect()
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = guardedCallback("services-discovered") {
            log("Oura: services discovered (status=$status)")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("Oura: WARNING service discovery failed (status=$status) - giving up on this ring")
                return@guardedCallback
            }
            // Request the gen-appropriate MTU (gen3=203, gen4/5=247) so multi-record notifications and
            // the auth proof fit. The flow continues from onMtuChanged (or falls through if it fails).
            log("Oura: requesting MTU ${ringGen.mtu}")
            val requested = runCatching { g.requestMtu(ringGen.mtu) }.getOrDefault(false)
            if (!requested) {
                // Some stacks reject requestMtu; proceed at the default MTU rather than stall.
                log("Oura: MTU request not accepted - proceeding at default MTU")
                setUpNotifications(g)
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) = guardedCallback("mtu-changed") {
            log("Oura: MTU negotiated = $mtu (status=$status)")
            setUpNotifications(g)
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) = guardedCallback("descriptor-write") {
            if (descriptor.uuid != CCCD) return@guardedCallback
            if (status == BluetoothGatt.GATT_SUCCESS) {
                log("Oura: notifications enabled (CCCD write status=$status) - beginning auth")
                // Notifications are live: tell the driver we are Ready. It returns the enable-notify +
                // get-nonce commands (or drives the honest needs-pairing path when there is no app key).
                advance(OuraTransition.Ready)
            } else {
                log("Oura: WARNING CCCD write FAILED (status=$status) - ring will send no data")
                announceNeedsPairing(KEY_INSTALL_MESSAGE)
            }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (ch.uuid == NOTIFY_UUID) handleNotification(value)
        }

        // Legacy (< API 33) characteristic-changed callback: read the value off the characteristic.
        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (ch.uuid == NOTIFY_UUID) handleNotification(ch.value ?: return)
        }
    }

    /** Resolve the write/notify characteristics, enable notifications on ...0003, and write the CCCD.
     *  The auth flow begins from onDescriptorWrite once the CCCD write is acknowledged. */
    private fun setUpNotifications(g: BluetoothGatt) = guardedCallback("setup-notify") {
        val svc = g.getService(SERVICE_UUID)
        if (svc == null) {
            log("Oura: base service NOT FOUND - this peripheral is not a supported Oura ring")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        writeChar = svc.getCharacteristic(WRITE_UUID)
        notifyChar = svc.getCharacteristic(NOTIFY_UUID)
        val notify = notifyChar
        if (writeChar == null || notify == null) {
            log("Oura: write/notify characteristics NOT FOUND - cannot drive the ring")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        log("Oura: write + notify characteristics found - enabling notifications on the notify char")
        g.setCharacteristicNotification(notify, true)
        val cccd = notify.getDescriptor(CCCD)
        if (cccd == null) {
            log("Oura: WARNING notify char has no CCCD (0x2902) - cannot enable notifications")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val rc = g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            log("Oura: CCCD write requested (rc=$rc)")
        } else {
            @Suppress("DEPRECATION")
            run {
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                val ok = g.writeDescriptor(cccd)
                log("Oura: CCCD write requested (rc=$ok)")
            }
        }
    }

    // MARK: - Driver flow

    /** Feed a transport transition to the driver and write back the commands it returns. After the
     *  enable triplet completes the driver reports Streaming; we then begin the periodic re-engage. */
    private fun advance(transition: OuraTransition) = guardedCallback("advance") {
        val d = driver ?: return@guardedCallback
        val commands = d.nextStep(transition)
        for (cmd in commands) write(cmd)
        when (d.phase) {
            OuraDriverPhase.Streaming -> {
                // The driver returns to Streaming after EACH history-fetch pass completes, so gate all the
                // one-shot streaming work on reachedStreaming (twin of Swift's `if !reachedStreaming`) - it
                // must run exactly once per connection, not on every history summary.
                if (!reachedStreaming) {
                    reachedStreaming = true
                    // Re-auth after an install (or a normal auth) reached the stream: adoption is complete.
                    // The OK ack already persisted the key; nothing is left in flight.
                    _adoptPhase.value = AdoptPhase.Streaming
                    pendingInstallKey = null
                    log("Oura: live HR enabled - streaming")
                    scheduleReengage()
                    // Pull last night's banked temp/SpO2/HRV/sleep-phase right away + keep a periodic pass
                    // running, and ask for battery once (the 0x0D reply routes to onBattery).
                    scheduleHistoryFetch()
                    fetchHistoryIfIdle()
                    write(OuraCommands.getBattery())
                }
            }
            OuraDriverPhase.NeedsKeyInstall -> {
                // Factory-reset ring (auth status 0x02) or no key. The dangerous key install is the ONLY
                // thing that recovers it, and ONLY with explicit adopt consent: provision when adoptIntent,
                // otherwise stay honest and never loop the dangerous command.
                if (adoptIntent) provisionKeyInstall(d) else announceNeedsPairing(KEY_INSTALL_MESSAGE)
            }
            is OuraDriverPhase.AuthFailed -> {
                log("Oura: auth failed - the stored install key does not match this ring")
                announceNeedsPairing(AUTH_FAILED_MESSAGE)
            }
            else -> Unit
        }
    }

    // MARK: - Adopt key-install handshake (s3.2) - ONLY ever reached with explicit adopt consent

    /**
     * PROVISION a fresh key into a factory-reset ring (OURA_PROTOCOL.md s3.2). Reached ONLY from [advance]
     * when the driver phase is NeedsKeyInstall AND [adoptIntent] is true. Steps:
     *   1. generate a fresh cryptographically-random 16-byte key;
     *   2. ask the driver for the dangerous `24 10 <key>` install command (the driver's own
     *      `allowKeyInstall`/phase gate is the second guard) and write it;
     *   3. hold the key in memory and mark [AdoptPhase.InstallingKey] (an install IS now running).
     * The key is NOT persisted yet: it is written to the keystore only once the ring acks OK
     * ([handleKeyInstallAck]), so a failed install never leaves a key the next session would wrongly trust.
     * On any RNG/build failure we stay honest (announceNeedsPairing) and never retry the dangerous command.
     * Kotlin twin of Swift's `provisionKeyInstall`.
     */
    private fun provisionKeyInstall(d: OuraDriver) = guardedCallback("provision-key") {
        if (!adoptIntent) return@guardedCallback             // belt-and-braces: never provision without consent
        if (pendingInstallKey != null) return@guardedCallback // an install is already in flight; don't double-send
        val key = runCatching { randomKey() }.getOrNull()
        if (key == null || key.size != OuraAuth.keyLength || key.any { it !in 0..255 }) {
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        val cmd = d.beginKeyInstall(key)
        if (cmd == null) {
            // The driver refused (wrong phase / not allowed / build failed): stay honest, never retry blind.
            log("Oura: the install command could not be prepared - staying honest")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        pendingInstallKey = key
        _adoptPhase.value = AdoptPhase.InstallingKey
        log("Oura: installing NOOP's key on the reset ring")
        write(cmd)
    }

    /**
     * Handle the ring's `0x25` SetAuthKey ack (OURA_PROTOCOL.md s3.2: `25 01 00`, status byte `0x00` = OK).
     * Acts ONLY when an install we initiated is in flight (a pending key is held AND driver phase is
     * InstallingKey); a stray 0x25 outside an adopt is ignored. On OK: PERSIST the freshly-provisioned key
     * under this deviceId (so every future session authenticates with it), then drive the driver's
     * keyInstallAcknowledged() to re-run the auth handshake (GetAuthNonce then Authenticate) with the NEW
     * key. On a non-OK status (or a failed store) announce an honest failure and do NOT retry the dangerous
     * command. Kotlin twin of Swift's `handleKeyInstallAck`.
     */
    private fun handleKeyInstallAck(d: OuraDriver, frame: OuraOuterFrame) = guardedCallback("key-install-ack") {
        val key = pendingInstallKey ?: return@guardedCallback              // no install in flight
        if (d.phase != OuraDriverPhase.InstallingKey) return@guardedCallback // not our install in flight
        val status = frame.body.firstOrNull()
        if (status == SET_AUTH_KEY_OK) {
            // Persist ONLY on OK, so a failed/absent ack never leaves a wrongly-trusted key behind.
            if (!OuraInstallKeyStore.save(appContext, deviceId, key)) {
                log("Oura: the installed key could not be stored - cannot adopt this ring")
                announceNeedsPairing(KEY_INSTALL_MESSAGE)
                return@guardedCallback
            }
            log("Oura: key installed and stored - re-authenticating with the new key")
            pendingInstallKey = null
            // Re-auth with the freshly-installed key. The driver returns enable-notify + get-nonce; the
            // nonce response then flows through the normal routeSecure -> advance path to streaming.
            for (cmd in d.keyInstallAcknowledged()) write(cmd)
        } else {
            log("Oura: the ring did not accept the key (status=${status ?: "none"}) - cannot adopt this ring")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
        }
    }

    /** Write one built command to the ring's write characteristic (Write Without Response). Logged by its
     *  short label only (never bytes or an address). */
    private fun write(cmd: OuraCommand) = guardedCallback("write") {
        val g = gatt ?: return@guardedCallback
        val ch = writeChar ?: return@guardedCallback
        val bytes = ByteArray(cmd.bytes.size) { cmd.bytes[it].toByte() }
        log("Oura: → ${cmd.label}")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(ch, bytes, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)
        } else {
            @Suppress("DEPRECATION")
            run {
                ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                ch.value = bytes
                g.writeCharacteristic(ch)
            }
        }
    }

    /**
     * Handle one inbound notification value. Two framing layers ride the same notify char (s2):
     *   - 0x2F secure-session sub-frames carry the auth nonce/status, live-HR pushes, and enable ACKs.
     *   - everything else is one or more TLV event records (reassembled across notifications).
     * The pure driver owns every decode; we only route bytes and turn its results into transitions /
     * persisted rows. A throw anywhere here is contained by [guardedCallback] (degrade to "no data").
     */
    private fun handleNotification(data: ByteArray) = guardedCallback("notification") {
        val d = driver ?: return@guardedCallback
        val bytes = IntArray(data.size) { data[it].toInt() and 0xFF }
        // Split any packed outer frames; route 0x2F secure sub-frames through the driver's secure handler
        // and feed all other bytes to the TLV reassembler.
        val nonSecure = ArrayList<Int>()
        for (frame in OuraFraming.parseOuterFrames(bytes)) {
            if (frame.op == OuraFraming.secureSessionOp) {
                val secure = OuraFraming.parseSecureFrame(frame) ?: continue
                routeSecure(d, secure)
            } else if (frame.op == SET_AUTH_KEY_RESP_OP) {
                // The post-factory-reset key-install acknowledgement (`25 01 00`, OURA_PROTOCOL.md s3.2):
                // an OUTER frame, not a 0x2F secure sub-frame and not a TLV record. Route it to the adopt
                // handler ONLY (it self-guards: it acts solely when an install we initiated is in flight).
                handleKeyInstallAck(d, frame)
            } else if (frame.op == OuraFraming.getEventsResponseOp) {
                // The `0x11` GetEvents summary drives the history-fetch cursor loop (OURA_PROTOCOL.md
                // s5.2/5.3): an OUTER frame, never a TLV record. Its op (0x11) is well below the event-tag
                // range (tags are >= 0x41), so had it fallen through to the reassembler it would decode as a
                // safe "unknown tag" no-op; we route it to the cursor loop instead (same convention as the
                // 0x25 ack above - handled, not re-serialised).
                val summary = OuraFraming.parseGetEventsResponse(frame.body)
                if (summary != null) handleHistorySummary(summary)
            } else if (frame.op == OuraFraming.batteryResponseOp) {
                // The `0x0D` GetBattery response is ALSO an OUTER frame (never a TLV record, s6.10). Its op
                // is below the event-tag range too, so it is a safe no-op if it ever fell through; we route
                // it through the existing `.battery` ingest path (batteryPct/onBattery/log side effects).
                val battery = OuraDecoders.decodeBattery(frame.body)
                if (battery != null) emit(listOf(OuraEvent.Battery(battery)))
            } else {
                // Re-serialise the outer frame (op, len, body) so the reassembler sees the original wire
                // bytes; TLV records and outer frames share the op/len header shape.
                nonSecure.add(frame.op)
                nonSecure.add(frame.body.size)
                for (b in frame.body) nonSecure.add(b)
            }
        }
        if (nonSecure.isNotEmpty()) {
            val records = reassembler.feed(IntArray(nonSecure.size) { nonSecure[it] })
            for (rec in records) emit(d.ingest(rec))
        }
    }

    /** Route a 0x2F secure sub-frame to the driver and turn its result into a transition or live events. */
    private fun routeSecure(d: OuraDriver, secure: com.noop.oura.OuraSecureFrame) = guardedCallback("secure-route") {
        when (val routing = d.handleSecureFrame(secure)) {
            is OuraDriver.SecureRouting.Nonce -> advance(OuraTransition.NonceReceived(routing.nonce))
            is OuraDriver.SecureRouting.AuthStatus -> {
                log("Oura: auth status = ${routing.status.name}")
                advance(OuraTransition.AuthCompleted(routing.status))
            }
            OuraDriver.SecureRouting.EnableAck -> advance(OuraTransition.EnableAckReceived)
            is OuraDriver.SecureRouting.LiveHRPush -> emit(d.ingestLiveHRPush(routing.body))
            OuraDriver.SecureRouting.Unhandled -> Unit
        }
    }

    /**
     * Fold decoded driver events into live-UI updates + the persist buffer (the production path, parity
     * with Swift's `ingest`). Live-push events (HR/IBI/battery) are stamped at wall-clock arrival time,
     * since they genuinely are "now"; HR is range-gated for the LIVE display (off-finger / garbage never
     * shown) and battery surfaces immediately (a status, not a timestamped row). History-fetched events
     * (temp, SpO2, HRV, sleep-phase - SLEEP-ONLY on this hardware, never a live readout) are stamped with
     * their REAL ring-time-anchored UTC (s5.5) so last night's data is never mis-recorded as happening
     * right now; when no anchor has arrived yet this session, the event is PARKED
     * ([pendingAnchorEvents]) until one does, rather than immediately guessing wall-clock. A 0x42
     * time-sync (the anchor) drains anything parked. Tier-B events (allowed for INVESTIGATION - see the
     * driver construction comment) are LOGGED only, never enqueued: OuraStreamMapping drops them anyway,
     * so an unverified layout can never feed a durable stream or scoring.
     */
    private fun emit(events: List<OuraEvent>) = guardedCallback("emit") {
        if (events.isEmpty()) return@guardedCallback
        val d = driver ?: return@guardedCallback
        val now = (System.currentTimeMillis() / 1000L).toInt()
        for (e in events) when (e) {
            is OuraEvent.Hr -> {
                val bpm = e.value.bpm
                if (bpm in 30..220) {   // physiological gate for the LIVE readout only
                    if (!loggedFirstHr) {
                        loggedFirstHr = true
                        log("Oura: receiving data - first sample $bpm bpm")
                    }
                    handler.post { guardedCallback("live-sink") { liveSink(bpm, emptyList()) } }
                }
                enqueue(listOf(e), now)
            }
            is OuraEvent.Ibi -> {
                val rr = e.value.ibiMs
                if (rr in 250..3000) handler.post { guardedCallback("live-sink") { liveSink(0, listOf(rr)) } }
                enqueue(listOf(e), now)
            }
            is OuraEvent.Battery -> {
                handleBattery(e.value.percent)
                enqueue(listOf(e), now)
            }
            is OuraEvent.Temp -> {
                // physiological gate (wrist skin temp); an out-of-range read is dropped, never shown.
                if (e.value.celsius in 20.0..45.0) {
                    if (!loggedFirstTemp) {
                        loggedFirstTemp = true
                        log("Oura: first skin temp decoded (last night) - %.2fC".format(e.value.celsius))
                    }
                    enqueueAnchoredOrPark(e, e.value.ringTimestamp, d)
                }
            }
            is OuraEvent.Spo2 -> {
                if (!loggedFirstSpo2) {
                    loggedFirstSpo2 = true
                    log("Oura: first SpO2 decoded (last night) - value ${e.value.value} (${e.value.unit})")
                }
                enqueueAnchoredOrPark(e, e.value.ringTimestamp, d)
            }
            is OuraEvent.Hrv -> enqueueAnchoredOrPark(e, e.value.ringTimestamp, d)
            is OuraEvent.SleepPhaseEvent -> enqueueAnchoredOrPark(e, e.value.ringTimestamp, d)
            is OuraEvent.TimeSyncEvent -> {
                if (!loggedAnchor) {
                    loggedAnchor = true
                    log("Oura: UTC time anchor acquired - history-fetched samples now get their real time")
                }
                // The 0x42 time-sync can arrive ANYWHERE in a history-fetch stream, not necessarily first.
                // Anything parked while unanchored gets its real time retroactively the moment it lands.
                drainPendingAnchorEvents()
            }
            is OuraEvent.TierB -> {
                // INVESTIGATION ONLY (real_steps / activity-summary / sleep-summary / smoothed-SpO2,
                // OURA_PROTOCOL.md s7.3 Tier B; PR #960). Logged ONCE PER KIND with the raw bytes so we
                // can see whether the ring sends these tags at all and collect capture material - e.g.
                // real_steps 0x7E/0x7F is server-flag-gated OFF by default ([open_oura-feat]), so its
                // continued absence here is the ring's doing, not a decode gap. Never persisted, never
                // scored (OuraStreamMapping drops TierB unconditionally regardless of this log).
                if (loggedTierBKinds.add(e.value.kind)) {
                    val hex = e.value.rawPayload.joinToString(" ") { "%02x".format(it) }
                    log("Oura: Tier-B ${e.value.kind} seen (tag 0x${e.value.tag.toString(16)}) - raw: $hex")
                }
            }
            is OuraEvent.ActivityInfo ->
                // INVESTIGATION ONLY (0x50 activity/MET, Tier B - a plausible third-party formula, NOT
                // ground-truth-validated; see OuraActivityInfo). Logged with the DECODED state/MET values
                // every time (not once-per-kind): this is the tag under active plausibility evaluation, so
                // every real capture is evidence. Never persisted, never scored, and NEVER converted into
                // steps (MET is not a step count; OuraStreamMapping drops ActivityInfo unconditionally).
                log("Oura: activity (Tier-B) state=${e.value.state} met=${e.value.met}")
            // Motion / state / rtcBeacon / debugText: not a durable Streams row (see OuraStreamMapping).
            else -> Unit
        }
    }

    /**
     * Stamp a history-fetched event with its ring-time-anchored UTC (s5.5) and enqueue it, or - when no
     * anchor has arrived yet this session - park it in [pendingAnchorEvents] to be re-stamped the moment
     * one lands (drained by a 0x42 time-sync, or with an honest wall-clock fallback at teardown). Kotlin
     * twin of the Swift `if let ts = driver.unixSeconds(...) { enqueue } else { pendingAnchorEvents.append }`
     * pattern repeated per history signal.
     */
    private fun enqueueAnchoredOrPark(event: OuraEvent, ringTimestamp: Long, d: OuraDriver) {
        val ts = d.unixSeconds(forRingTimestamp = ringTimestamp)
        if (ts != null) enqueue(listOf(event), ts.toInt()) else pendingAnchorEvents.add(event to ringTimestamp)
    }

    private fun handleBattery(pct: Int) = guardedCallback("battery") {
        if (pct !in 0..100) return@guardedCallback
        log("Oura: battery $pct%")
        _batteryPct.value = pct
        // Battery is NOT persisted as a stream row here: it carries no ring timestamp, and OuraStreamMapping
        // intentionally drops it (honest: no faked ts). It flows only via the live onBattery path, exactly
        // like the Swift twin.
        handler.post { guardedCallback("battery-sink") { onBattery(pct) } }
    }

    // MARK: - Live-HR re-engage scheduling

    private fun scheduleReengage() {
        if (reengageScheduled) return
        reengageScheduled = true
        handler.postDelayed(reengageRunnable, reengageIntervalMs)
    }

    private fun cancelReengage() {
        reengageScheduled = false
        handler.removeCallbacks(reengageRunnable)
    }

    // MARK: - Honest fallback

    /**
     * Record the honest "this ring needs a pairing handshake NOOP can't complete" outcome (the message is
     * already RECOVERY-HONEST: a factory-reset ring is NOT bricked, re-pairing in the Oura app brings it
     * back, and adopt is Beta). Also marks [AdoptPhase.Failed] so an in-flight adopt's Adopting step lands
     * on a REACHABLE honest Failed state, and clears any in-flight install key WITHOUT persisting it (a
     * failed install must never leave a wrongly-trusted key). We never claim a key was installed here.
     * Mirrors the Swift `announceNeedsPairing`.
     */
    private fun announceNeedsPairing(message: String) {
        // A failed install must drop its pending key whether or not this is the first announce.
        pendingInstallKey = null
        _adoptPhase.value = AdoptPhase.Failed
        // This is an honest dead-end (no key / auth rejected / install failed), NOT a transient drop, so a
        // later disconnect must NOT auto-reconnect (that would loop the same auth failure and drain the
        // ring). Suppress it the same way a deliberate teardown does (#912); a user reconnect re-arms it.
        intentionalDisconnect = true
        reconnectAddress = null
        failedReconnectAttempts = 0
        if (_needsPairing.value != null) return
        _needsPairing.value = message
        log("Oura: $message")
    }

    /**
     * Run a GATT-callback body so a throw on the binder thread (or a posted main-thread block) can never
     * crash the app. BLE callbacks run outside any try/catch and outside the SourceCoordinator reconcile
     * guard, so an exception in a decode / live sink would otherwise crash the process - and because the
     * ring is the persisted active source, it would crash-LOOP on every launch (#421 regression). A
     * misbehaving ring must degrade to "no data", never take the app down. The message lands in the
     * exportable strap log. Mirrors [StandardHrSource.guardedCallback].
     */
    private fun guardedCallback(label: String, block: () -> Unit) {
        runCatching(block).onFailure {
            log("Oura: $label error (${it.javaClass.simpleName}: ${it.message})")
        }
    }

    companion object {
        /** The ring's base service + write/notify characteristics (OURA_PROTOCOL.md s1.1). Built from the
         *  protocol package's UUID strings so the facts live in exactly one place. */
        val SERVICE_UUID: UUID = UUID.fromString(OuraGatt.serviceUUID)
        val WRITE_UUID: UUID = UUID.fromString(OuraGatt.writeCharacteristicUUID)
        val NOTIFY_UUID: UUID = UUID.fromString(OuraGatt.notifyCharacteristicUUID)

        /** The standard client-characteristic-configuration descriptor (0x2902). */
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Android's infamous generic GATT connect failure (`BluetoothGatt.GATT_ERROR`, not a public
         *  constant). We auto-retry it once. */
        private const val GATT_ERROR_133 = 133

        /** The SetAuthKey-response OUTER opcode (`0x25`) and its OK status byte (`0x00`). The ring replies
         *  `25 01 00` to a successful `0x24` key install (OURA_PROTOCOL.md s3.2). */
        private const val SET_AUTH_KEY_RESP_OP = 0x25
        private const val SET_AUTH_KEY_OK = 0x00

        /** Generate a fresh cryptographically-random 16-byte install key as unsigned bytes 0..255
         *  (OURA_PROTOCOL.md s3.2 step 1). [java.security.SecureRandom] is the platform CSPRNG. */
        private fun secureRandom16(): IntArray {
            val bytes = ByteArray(OuraAuth.keyLength)
            SecureRandom().nextBytes(bytes)
            return IntArray(OuraAuth.keyLength) { bytes[it].toInt() and 0xFF }
        }

        /**
         * Honest fallback copy: live data is not available, AND the ring is RECOVERABLE. A factory-reset
         * ring is not bricked: re-pairing it in the Oura app sets it up again. NOOP adopt is Beta and may
         * not succeed on every ring or firmware yet. No "installing key" wording (no install ran here).
         */
        private const val KEY_INSTALL_MESSAGE =
            "NOOP couldn't pair with this Oura ring. Live data isn't available. The ring is not damaged: " +
                "re-pair it in the Oura app to set it up again. NOOP adopt is Beta and may not work on " +
                "every ring or firmware yet. You can also export from the Oura app and use file import."

        /** Honest fallback copy: a key IS installed but it does not match this ring. Same recovery note. */
        private const val AUTH_FAILED_MESSAGE =
            "This Oura ring rejected the stored pairing key. Live data isn't available. The ring is not " +
                "damaged: re-pair it in the Oura app to set it up again, or export from the Oura app and " +
                "use file import."
    }
}

// MARK: - Oura GetEvents cursor persistence

/**
 * Persists the Oura `GetEvents` cursor (OURA_PROTOCOL.md s5.1/5.3) per ring, so a later connection
 * resumes from where the last session left off instead of re-fetching the ring's entire banked history on
 * every single connect. Kotlin twin of Swift's `OuraHistoryCursorStore` (which uses `UserDefaults`).
 *
 * Unlike [OuraInstallKeyStore] this is NOT sensitive - it's an opaque ring-clock tick counter, not a
 * credential - so plain [SharedPreferences] is the right (and simplest) store (no EncryptedSharedPreferences
 * / keystore round-trip). The cursor is the unsigned 32-bit ring timestamp; it is stored as a Long (the JVM
 * has no unsigned int) so the full 0..0xFFFFFFFF range survives a round-trip.
 */
object OuraHistoryCursorStore {
    private const val FILE_NAME = "noop_oura_history_cursor"
    private const val KEY_PREFIX = "history_cursor_"

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    private fun prefKey(deviceId: String) = "$KEY_PREFIX$deviceId"

    /** The persisted cursor for [deviceId], or 0 (fetch everything) if none is stored yet. Clamped to the
     *  unsigned-32 range so a corrupt/negative stored value can never drive a malformed GetEvents request. */
    fun read(ctx: Context, deviceId: String): Long {
        val raw = runCatching { prefs(ctx).getLong(prefKey(deviceId), 0L) }.getOrDefault(0L)
        return raw.coerceIn(0L, 0xFFFF_FFFFL)
    }

    /** Store the advanced cursor for [deviceId]. */
    fun save(ctx: Context, deviceId: String, cursor: Long) {
        runCatching { prefs(ctx).edit().putLong(prefKey(deviceId), cursor and 0xFFFF_FFFFL).apply() }
    }
}
