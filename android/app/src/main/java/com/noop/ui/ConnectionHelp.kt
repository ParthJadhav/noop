package com.noop.ui

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * In-app connection walkthrough. The number-one reason a strap won't connect is the official
 * WHOOP app holding it (a strap only pairs with ONE app at a time), followed by Bluetooth being
 * off or the runtime permission not granted. This card detects each blocker and gives a one-tap
 * fix, including deep-linking straight to the WHOOP app's info screen so the user can Force stop it.
 *
 * Shown on the Live screen whenever the strap isn't bonded yet; it disappears once connected.
 */
@Composable
fun ConnectionHelp(viewModel: AppViewModel, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    // Re-read the live state so the checks below re-evaluate after the user fixes something.
    val live by viewModel.live.collectAsStateWithLifecycle()

    val perms = remember {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }
    val btOn = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)
        ?.adapter?.isEnabled == true
    val permGranted = perms.all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }
    val whoopInstalled = remember { packageInstalled(context, WHOOP_PACKAGE) }

    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { viewModel.connect() }
    val enableBtLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { /* user toggled Bluetooth; recomposition re-reads btOn */ }

    // A WHOOP 5/MG strap is a different situation: it DID connect (battery reads), so the generic
    // "is it on / is the WHOOP app holding it" checklist is misleading. Tell the user the honest
    // truth instead — the strap and their setup are fine; the live-data handshake just isn't ready.
    if (live.whoop5Detected) {
        NoopCard(modifier = modifier) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("WHOOP 5 / MG (experimental)", style = NoopType.headline, color = Palette.textPrimary)
                Text(
                    "Your strap is connected and we're trying an experimental handshake to bring up live " +
                        "heart rate from the standard profile. This isn't verified on 5/MG hardware yet, so " +
                        "HR may or may not appear, and deeper metrics (recovery, strain, sleep) aren't " +
                        "decoded for 5/MG yet. Nothing's wrong with your strap - WHOOP 4.0 is fully supported.",
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
        }
        return
    }

    NoopCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("Won't connect? Run through these", style = NoopType.headline, color = Palette.textPrimary)

            HelpStep(
                done = !whoopInstalled,
                title = "Close the official WHOOP app",
                body = "Your strap only pairs with ONE app at a time. If the WHOOP app is connected, " +
                    "NOOP can't reach the strap. Force stop it (swiping it out of recents isn't enough).",
                actionLabel = if (whoopInstalled) "Open WHOOP app, then Force stop" else "WHOOP app isn't installed",
                enabled = whoopInstalled,
                onAction = { openAppInfo(context, WHOOP_PACKAGE) },
            )
            HelpStep(
                done = btOn,
                title = "Turn Bluetooth on",
                body = if (btOn) "Bluetooth is on." else "Bluetooth is currently off.",
                actionLabel = if (!btOn) "Turn on Bluetooth" else null,
                enabled = !btOn,
                onAction = {
                    runCatching { enableBtLauncher.launch(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)) }
                },
            )
            HelpStep(
                done = permGranted,
                title = "Allow Nearby devices",
                body = if (permGranted) "Permission granted."
                else "On Android 12+, \"Nearby devices\" is the Bluetooth permission. NOOP needs it to find your strap.",
                actionLabel = if (!permGranted) "Grant permission" else null,
                enabled = !permGranted,
                onAction = { permLauncher.launch(perms) },
            )
            HelpStep(
                done = false,
                title = "Charge it and put it on",
                body = "A flat or off-wrist strap won't advertise, so nothing shows up. A real phone is " +
                    "required too: an emulator has no Bluetooth.",
                actionLabel = null,
                enabled = false,
                onAction = {},
            )

            OutlinedButton(
                onClick = { if (permGranted) viewModel.connect() else permLauncher.launch(perms) },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Try connecting now", style = NoopType.body) }
        }
    }
}

@Composable
private fun HelpStep(
    done: Boolean,
    title: String,
    body: String,
    actionLabel: String?,
    enabled: Boolean,
    onAction: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            (if (done) "✓  " else "•  ") + title,
            style = NoopType.subhead,
            color = if (done) Palette.accent else Palette.textPrimary,
        )
        Text(body, style = NoopType.footnote, color = Palette.textSecondary)
        if (actionLabel != null) {
            OutlinedButton(onClick = onAction, enabled = enabled) {
                Text(actionLabel, style = NoopType.footnote)
            }
        }
    }
}

private const val WHOOP_PACKAGE = "com.whoop.android"

/** True if [pkg] is installed (used to detect the official WHOOP app). */
private fun packageInstalled(ctx: Context, pkg: String): Boolean =
    try { ctx.packageManager.getPackageInfo(pkg, 0); true } catch (e: Exception) { false }

/** Open an installed app's info screen (where the user can tap Force stop). */
private fun openAppInfo(ctx: Context, pkg: String) {
    runCatching {
        ctx.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", pkg, null))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
