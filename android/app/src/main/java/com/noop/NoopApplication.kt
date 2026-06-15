package com.noop

import android.app.Application
import android.util.Log
import com.noop.ble.WhoopBleClient
import com.noop.data.DeviceRegistry
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.runBlocking

/**
 * Application entry point.
 *
 * NOOP is a fully on-device WHOOP companion: it connects to the strap over BLE and persists
 * everything locally via Room. There is no network layer (the opt-in AI Coach aside).
 *
 * The data layer ([WhoopRepository]) and the BLE client ([WhoopBleClient]) are owned **here**, at the
 * process level, rather than by the Activity-scoped AppViewModel. That is what lets a connection keep
 * streaming when the app is backgrounded or closed: [com.noop.ble.WhoopConnectionService] holds the
 * process up with a foreground notification, and both it and the UI share this one BLE client. The
 * macOS app gets the same outcome for free — its `AppModel` is an app-level `@StateObject` kept alive
 * by the menu-bar extra.
 */
class NoopApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        // Record any uncaught crash to a file so it rides along in the shareable strap log — a
        // device-specific crash (e.g. Insights #224/#267) is otherwise lost to an unreachable logcat.
        CrashCapture.install(this)
    }

    /** Process-wide Room-backed store. One instance shared by the UI and the background service. */
    val repository: WhoopRepository by lazy {
        WhoopRepository(WhoopDatabase.get(this).whoopDao())
    }

    /** Process-wide device registry over the same Room DB — the single source of the active device id. */
    val deviceRegistry: DeviceRegistry by lazy { DeviceRegistry(WhoopDatabase.get(this)) }

    /**
     * Active device id resolved once at startup from the registry, falling back to the legacy
     * "my-whoop" if the registry has none yet (so behaviour is unchanged today). Read with a guarded
     * blocking call — a one-off indexed `LIMIT 1` query at composition time. Any failure (e.g. an early
     * read before migration) is swallowed and falls back, so startup can never be broken by this.
     */
    val activeDeviceId: String by lazy {
        runCatching { runBlocking { deviceRegistry.activeDeviceId() } }
            .onFailure { Log.w("NoopApplication", "activeDeviceId resolve failed; using fallback", it) }
            .getOrNull() ?: WhoopBleClient.DEFAULT_DEVICE_ID
    }

    /** Process-wide BLE client. Owns the GATT connection and outlives any single Activity/ViewModel. */
    val ble: WhoopBleClient by lazy {
        WhoopBleClient(applicationContext, repository = repository, deviceId = activeDeviceId).apply {
            // Apply the persisted "Debug logging" preference at the composition root so the low-level
            // client never has to read the UI/prefs layer. Default OFF — see WhoopBleClient.debugLogcat.
            debugLogcat = NoopPrefs.debugLogging(applicationContext)
        }
    }
}
