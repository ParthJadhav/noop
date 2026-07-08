package com.noop.testcentre

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager

/**
 * The Android environment-header block (spec section 3.4), bringing Android to the same shape as the iOS
 * IOSDiagnostics. macOS and Android emit almost nothing today; this carries the variables that quietly
 * break a background BLE health app: Doze / battery-optimisation exemption, OEM-kill heuristics, the
 * permission-grant state, the charging state, and the Build identity.
 *
 * TOTAL and best-effort: every probe is guarded so a header build never throws into the export. Degrades
 * gracefully, never fabricates a value it can't read.
 */
object AndroidDiagnostics {

    fun summaryLines(context: Context): List<String> = buildList {
        add("Device: ${Build.MANUFACTURER} ${Build.MODEL}")
        add("Android: ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})")
        add("Battery optimisation: ${batteryOptimisationText(context)}")
        add("OEM background kill: ${oemKillHeuristic(Build.MANUFACTURER)}")
        add("Charging: ${chargingText(context)}")
        add("Permissions: ${permissionsText(context)}")
    }

    /** Doze exemption: an app NOT exempt from battery optimisation is the #1 cause of missed overnight
     *  background work on Android. */
    private fun batteryOptimisationText(context: Context): String = runCatching {
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        when (pm?.isIgnoringBatteryOptimizations(context.packageName)) {
            true -> "exempt (background work allowed)"
            false -> "NOT exempt (Android may kill overnight background BLE)"
            null -> "unknown"
        }
    }.getOrDefault("unknown")

    /** A coarse OEM-kill heuristic by manufacturer (the aggressive-background-kill vendors). Pure and
     *  internal so it unit-tests without a Context (the suite stays Robolectric-free). */
    internal fun oemKillHeuristic(manufacturer: String): String {
        val m = manufacturer.lowercase()
        val aggressive = listOf("xiaomi", "oppo", "vivo", "huawei", "oneplus", "realme", "meizu")
        return if (aggressive.any { m.contains(it) }) "aggressive vendor ($m), whitelist NOOP to keep it alive"
        else "standard"
    }

    /** Charging state from the sticky battery intent / BatteryManager. */
    private fun chargingText(context: Context): String = runCatching {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        when (bm?.isCharging) {
            true -> "yes"
            false -> "no (on battery)"
            null -> "unknown"
        }
    }.getOrDefault("unknown")

    /** Grant state of the permissions a background strap app needs. */
    private fun permissionsText(context: Context): String {
        val checks = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add("BLUETOOTH_CONNECT" to Manifest.permission.BLUETOOTH_CONNECT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add("POST_NOTIFICATIONS" to Manifest.permission.POST_NOTIFICATIONS)
            add("LOCATION" to Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return checks.joinToString(", ") { (label, perm) ->
            val granted = runCatching {
                context.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
            }.getOrDefault(false)
            "$label=${if (granted) "granted" else "denied"}"
        }
    }
}
