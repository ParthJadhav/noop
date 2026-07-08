package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.BuildConfig
import com.noop.analytics.Baselines
import com.noop.ble.PuffinExperiment
import com.noop.ble.WhoopModel
import com.noop.testcentre.CaptureAccumulator
import com.noop.testcentre.CaptureKind
import com.noop.testcentre.DisplayPerformanceMonitor
import com.noop.testcentre.ReportReviewGate
import com.noop.testcentre.TestBundleAssembler
import com.noop.testcentre.TestCentre
import com.noop.testcentre.TestCentreLayout
import com.noop.testcentre.TestDomain
import com.noop.testcentre.TestMode
import com.noop.testcentre.TestModeRegistry
import com.noop.testcentre.TestReportFlow
import com.noop.testcentre.TestReportLink
import kotlinx.coroutines.launch

/**
 * Settings -> Test Centre (spec section 7), the Android twin of TestCentreView. Four sections: domain
 * test modes (rendered from the registry projection), diagnostic tools, export and auto-export, and
 * advanced/experimental. A NEW file because SettingsScreen.kt (132 KB) cannot grow. Section 1 renders
 * from TestCentreLayout.visibleModes; sections 2 to 4 re-host the same strap-log / recalibrate /
 * scheduled-export / experimental controls on the same bindings the Settings cards use. No em-dash.
 */
@Composable
fun TestCentreScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val testCentre = remember { TestCentre.from(context) }
    // CAPTURE-D: a UI scope to emit the data-volume line off the toggle-on path (a store read, so it can't
    // run inline in the non-suspend onToggle).
    val scope = rememberCoroutineScope()

    // The strap model the Settings #22 gate reads, mirrored here so the 5/MG block shows for a 5/MG only.
    val live by vm.live.collectAsStateWithLifecycle()
    val selectedModelName = remember {
        NoopPrefs.of(context).getString("noop.selectedWhoopModel", null)
    }
    // Match the Settings `showFiveMGControls` gate exactly: pref OR a live-detected 5/MG this session, so a
    // 5/MG connected before its pref is written still sees the experimental block. (SettingsScreen.kt:346.)
    val is5MG = selectedModelName == WhoopModel.WHOOP5_MG.name || live.whoop5Detected

    // A report awaiting the mandatory review-before-share gate (spec section 12). Non-null shows the
    // review dialog; confirming runs TestReportFlow.run.
    var pendingReport by remember { mutableStateOf<PendingReport?>(null) }

    // The Display frame monitor follows the screen: if the Display mode was already on when the screen
    // appears, (re)start it; always tear it down when the screen leaves so no Choreographer callback
    // survives a navigation away. The mode flag stays on (the user's test is still active); the monitor
    // resumes next time this screen is shown. This keeps the perpetual-callback contract: a callback
    // exists only while the Test Centre is on screen with the Display mode on.
    DisposableEffect(Unit) {
        if (testCentre.active(TestDomain.DISPLAY)) {
            // CAPTURE-D (#797): wire the data-volume provider so the monitor can emit ONE `dataVolume` line
            // read STRAIGHT from the store (not the reactive caches), against the registry's active strap id.
            DisplayPerformanceMonitor.dataVolumeProvider = { vm.repo.dataVolumeSnapshot(vm.activeStrapId) }
            DisplayPerformanceMonitor.start(context) { line ->
                vm.ble.externalLog(line, TestDomain.DISPLAY)
            }
        }
        onDispose { DisplayPerformanceMonitor.stop() }
    }
    // CAPTURE-D: emit the data-volume line once when the Display mode is active on entry. Kept off the
    // (non-suspend) DisposableEffect: the read hits the store, so it runs from a coroutine.
    LaunchedEffect(Unit) {
        if (testCentre.active(TestDomain.DISPLAY)) DisplayPerformanceMonitor.emitDataVolume()
    }

    ScreenScaffold(
        title = "Test Centre",
        subtitle = "Turn on a test for the thing that's wrong, wear the strap, then tap Report. Everything stays on this phone.",
    ) {
        // --- Section 1: Domain test modes ---
        SettingsSectionTC(
            icon = Icons.Filled.BugReport,
            title = "Test modes",
            blurb = "Each test logs extra detail for one part of the app while you wear the strap, then bundles it for a bug report.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                TestCentreLayout.visibleModes(is5MG).forEach { mode ->
                    TestModeRow(
                        mode = mode,
                        active = testCentre.active(mode.domain),
                        startedAtSeconds = testCentre.startedAt(mode.domain),
                        // #965: the shareable strap log the report exports, so the row's "K of N" is the
                        // HONEST per-mode captured-day count (CaptureAccumulator), not an elapsed-clock proxy.
                        // Recomputes with `live` (collected above) so the count updates as new days land.
                        logText = vm.ble.exportLogText(),
                        onToggle = { on ->
                            if (on) testCentre.activate(mode.domain) else testCentre.deactivate(mode.domain)
                            // Display & Performance owns a live frame monitor. It must run ONLY while the
                            // mode is on: start it on toggle-on (wiring its sink to the redacting DISPLAY
                            // log), tear it down on toggle-off so no Choreographer callback survives.
                            // Zero-cost when off.
                            if (mode.domain == TestDomain.DISPLAY) {
                                if (on) {
                                    // CAPTURE-D (#797): wire the data-volume provider (store-read, active id),
                                    // start the monitor, then emit the upfront dataVolume line off a scope.
                                    DisplayPerformanceMonitor.dataVolumeProvider =
                                        { vm.repo.dataVolumeSnapshot(vm.activeStrapId) }
                                    DisplayPerformanceMonitor.start(context) { line ->
                                        vm.ble.externalLog(line, TestDomain.DISPLAY)
                                    }
                                    scope.launch { DisplayPerformanceMonitor.emitDataVolume() }
                                } else {
                                    DisplayPerformanceMonitor.stop()
                                }
                            }
                        },
                        onReport = {
                            // Launched (#1002): buildPending is now suspend (storage probe reads the store).
                            scope.launch { pendingReport = buildPending(context, mode, vm.ble.exportLogText(), vm) }
                        },
                    )
                }
            }
        }

        // --- Section 2: Diagnostic tools ---
        DiagnosticToolsCard(vm)

        // --- Section 3: Export and auto-export ---
        ExportCard(
            vm = vm,
            onReport = {
                // Launched (#1002): buildPending is now suspend (storage probe reads the store).
                scope.launch { pendingReport = buildPending(context, MASTER_REPORT_MODE, vm.ble.exportLogText(), vm) }
            },
        )

        // --- Section 4: Advanced / experimental ---
        AdvancedCard(vm, is5MG)
    }

    pendingReport?.let { p ->
        ReportReviewDialog(
            previewText = p.gate.previewText,
            modeInactive = p.modeInactive,
            onCancel = { pendingReport = null },
            onShare = {
                p.gate.confirm()
                TestReportFlow.run(
                    context = context,
                    profile = p.profile,
                    title = p.title,
                    version = BuildConfig.VERSION_NAME,
                    platform = "Android",
                    osVersion = android.os.Build.VERSION.RELEASE ?: "?",
                    gate = p.gate,
                    entries = p.entries,
                )
                pendingReport = null
            },
        )
    }
}

/** A report staged for the mandatory review gate: the profile, its title, the already-redacted entries
 *  and the gate built over them. The Kotlin gate keeps its entries private, so we hold them here too to
 *  hand TestReportFlow.run the same list it reviews. [modeInactive] (#1002): the selected profile's test
 *  mode is not on at report time, so the bundle carries no capture for the very thing being reported -
 *  the review dialog warns off it (the #812 capture_check only grades ACTIVE modes, so it can't). */
private class PendingReport(
    val profile: TestDomain,
    val title: String,
    val entries: List<Pair<String, ByteArray>>,
    val gate: ReportReviewGate,
    val modeInactive: Boolean = false,
)

/** The "whole app" report profile for the section-3 manual Report button. MASTER is not a registry mode
 *  (it has no wear-and-capture flow), so the deep-link self-applies the test:all label via this. */
private val MASTER_REPORT_MODE = TestMode(
    domain = TestDomain.MASTER, title = "Bug report", blurb = "", icon = "ic_bug",
    priority = com.noop.testcentre.TestPriority.HIGH, captures = emptyList(),
    questionnaire = emptyList(), liveReadout = emptyList(),
    capture = com.noop.testcentre.CaptureKind.Toggle, includesScreenshot = false, requires5MG = false,
)

/** Assemble the redacted, capped bundle for a profile and wrap it in the review gate. Suspend (#1002):
 *  the storage probe reads the store, so the callers launch it on the UI scope; the dialog presents off
 *  the same `pendingReport` state a beat after the tap. */
private suspend fun buildPending(
    context: android.content.Context,
    mode: TestMode,
    logText: String,
    vm: AppViewModel,
): PendingReport {
    // #1002 REAL storage probe, replacing the Phase-1 zeros in meta.json:
    //  - db_bytes: the Room store's on-disk footprint (noop_whoop.db + its -wal/-shm sidecars);
    //  - rows: per-table row counts via the store (WhoopRepository.storageRowCounts);
    //  - raw_capture_bytes: the 5/MG frame-recorder JSONL on disk (both rotation generations).
    // Everything read, never guessed; when nothing was readable the probe stays null and meta keeps the
    // honest zeroed block. Mirrors the Swift TestCentreReport.storageProbe.
    val dbPath = context.getDatabasePath(com.noop.data.WhoopDatabase.DB_NAME)
    var dbBytes = 0L
    for (suffix in listOf("", "-wal", "-shm")) {
        val f = java.io.File(dbPath.path + suffix)
        if (f.exists()) dbBytes += f.length()
    }
    val rows = vm.repo.storageRowCounts()
    var rawBytes = 0L
    for (name in listOf(
        com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE,
        com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE + ".1",
    )) {
        val f = java.io.File(context.filesDir, name)
        if (f.exists()) rawBytes += f.length()
    }
    val storage = if (dbBytes > 0L || rows.isNotEmpty() || rawBytes > 0L) {
        com.noop.testcentre.TestBundleMeta.Storage(
            dbBytes = dbBytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
            rows = rows,
            rawCaptureBytes = rawBytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
        )
    } else {
        null
    }
    // #1002: the connected model - the scan/connect path persists the DETECTED family to this pref, so
    // it reflects the strap that actually linked; the display name matches the Swift wire value.
    val strapModel = NoopPrefs.of(context).getString("noop.selectedWhoopModel", null)
        ?.let { name -> runCatching { WhoopModel.valueOf(name).displayName }.getOrNull() }
    val entries = TestBundleAssembler.assemble(context, mode.domain, logText, storage, strapModel)
    val modeInactive = mode.domain != TestDomain.MASTER && !TestCentre.from(context).active(mode.domain)
    return PendingReport(mode.domain, mode.title, entries, ReportReviewGate(entries), modeInactive)
}

@Composable
private fun TestModeRow(
    mode: TestMode,
    active: Boolean,
    startedAtSeconds: Long?,
    logText: String,
    onToggle: (Boolean) -> Unit,
    onReport: () -> Unit,
) {
    var on by remember { mutableStateOf(active) }
    val elapsed = startedAtSeconds?.let { (System.currentTimeMillis() / 1000.0) - it }
    // #965: HONEST per-mode captured-day count for a guided row (distinct days THIS mode produced its own
    // trace on), read from the same log the report exports, so each active mode accumulates its OWN count
    // instead of every guided row sharing one elapsed number. null for a toggle mode (no "K of N") / when off.
    val capturedUnits: Int? =
        if (on && mode.capture is CaptureKind.Guided) {
            CaptureAccumulator.capturedDays(
                domain = mode.domain,
                reportText = logText,
                tzOffsetSeconds =
                    (java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000).toLong(),
            )
        } else {
            null
        }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(mode.title, style = NoopType.body, color = Palette.textPrimary)
                Text(
                    TestCentreLayout.statusText(mode, on, elapsed, capturedUnits),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
            Switch(
                checked = on,
                onCheckedChange = { on = it; onToggle(it) },
                colors = settingsSwitchColors(),
            )
        }
        Text(mode.blurb, style = NoopType.footnote, color = Palette.textTertiary)
        Row {
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onReport) {
                Text("Report", color = Palette.accent, style = NoopType.body)
            }
        }
    }
}

@Composable
private fun DiagnosticToolsCard(vm: AppViewModel) {
    val context = LocalContext.current
    var showRecalibrate by remember { mutableStateOf(false) }
    SettingsSectionTC(
        icon = Icons.Filled.Info,
        title = "Diagnostic tools",
        blurb = "Your strap log, a Charge recalibrate, and the device environment. Nothing leaves the phone unless you share it.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Strap log, the same exportLogText share the Settings Diagnostics button uses.
            NoopButton(
                text = "Share strap log (for bug reports)",
                leadingIcon = Icons.Filled.Upload,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                onClick = { LogExport.shareStrapLog(context, vm.ble.exportLogText()) },
            )
            // Recalibrate Charge baseline, the same Baselines.recalibrateRecoveryBaselines call.
            NoopButton(
                text = "Recalibrate Charge baseline",
                leadingIcon = Icons.Filled.Autorenew,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                onClick = { showRecalibrate = true },
            )
            // Environment dump: the strap log already carries the AndroidDiagnostics header (spec 3.4).
            NoopButton(
                text = "Copy environment dump",
                leadingIcon = Icons.Filled.Info,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                onClick = { LogExport.shareStrapLog(context, vm.ble.exportLogText()) },
            )
        }
    }
    if (showRecalibrate) {
        AlertDialog(
            onDismissRequest = { showRecalibrate = false },
            containerColor = Palette.surfaceOverlay,
            title = { Text("Recalibrate your Charge baseline?", style = NoopType.title2, color = Palette.textPrimary) },
            text = {
                Text(
                    "This restarts the roughly 4-night build-up for Charge and your HRV baseline. Your history stays.",
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    val nowSeconds = System.currentTimeMillis() / 1000L
                    val editor = NoopPrefs.of(context).edit()
                    Baselines.recalibrateRecoveryBaselines(editor, nowSeconds)
                    editor.apply()
                    showRecalibrate = false
                    vm.syncNow()
                }) { Text("Recalibrate", style = NoopType.body, color = Palette.accent) }
            },
            dismissButton = {
                TextButton(onClick = { showRecalibrate = false }) {
                    Text("Cancel", style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }
}

@Composable
private fun ExportCard(vm: AppViewModel, onReport: () -> Unit) {
    val context = LocalContext.current
    val settings = remember { DebugExportSettings.from(context) }
    var enabled by remember { mutableStateOf(settings.enabled) }
    var minutes by remember { mutableStateOf(settings.timeMinutes) }
    SettingsSectionTC(
        icon = Icons.Filled.Upload,
        title = "Export",
        blurb = "Report a bug with your log, or have NOOP drop a daily copy into its export folder.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            NoopButton(
                text = "Report a bug with my log",
                leadingIcon = Icons.Filled.BugReport,
                kind = NoopButtonKind.Primary,
                fullWidth = true,
                onClick = onReport,
            )
            // Daily auto-export, the same DebugExportSettings writes the Settings card uses.
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Daily auto-export", style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        "Android runs this via WorkManager (Doze may delay it).",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
                Switch(
                    checked = enabled,
                    onCheckedChange = {
                        enabled = it
                        settings.enabled = it
                        DebugExportScheduler.reschedule(context)
                    },
                    colors = settingsSwitchColors(),
                )
            }
            if (enabled) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Export time", style = NoopType.subhead, color = Palette.textPrimary)
                    }
                    TimeChip(
                        minutes = minutes,
                        accessibilityLabel = "Daily export time",
                        onPicked = {
                            minutes = it
                            settings.timeMinutes = it
                            DebugExportScheduler.applyTimeChange(context)
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun AdvancedCard(vm: AppViewModel, is5MG: Boolean) {
    val context = LocalContext.current
    val puffin = remember { PuffinExperiment.from(context) }
    var v2 by remember { mutableStateOf(puffin.experimentalSleepV2) }
    // Re-hosted Continuous-HRV toggle, bound to the SAME NoopPrefs key (noop.continuousHrv) the Settings
    // card uses, so flipping it here or there is one and the same setting (mirrors the iOS Test Centre).
    var continuousHrv by remember { mutableStateOf(NoopPrefs.continuousHrv(context)) }
    var probes by remember { mutableStateOf(puffin.isEnabled) }
    var deepData by remember { mutableStateOf(puffin.isDeepDataEnabled) }
    var broadcast by remember { mutableStateOf(puffin.broadcastHr) }
    var capture by remember { mutableStateOf(puffin.isCaptureEnabled) }
    SettingsSectionTC(
        icon = Icons.Filled.Info,
        title = "Advanced",
        blurb = "Experimental probes, off by default. The fuller WHOOP 5/MG controls and the raw-sensor CSV export still live in Settings under Diagnostics.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ToggleRowTC("Experimental sleep staging (V2)", v2) {
                v2 = it; puffin.experimentalSleepV2 = it
            }
            // Same write path as Settings: vm.setContinuousHrv persists noop.continuousHrv and re-applies
            // keep-stream-for-data, so the live capture follows the toggle from either screen.
            ToggleRowTC("Continuous HRV capture", continuousHrv) {
                continuousHrv = it; vm.setContinuousHrv(it)
            }
            if (is5MG) {
                ToggleRowTC("Try WHOOP 5/MG protocol probes", probes) {
                    probes = it; puffin.isEnabled = it
                }
                ToggleRowTC("Unlock WHOOP 5/MG deep data (R22)", deepData) {
                    deepData = it; puffin.isDeepDataEnabled = it
                }
                ToggleRowTC("Broadcast heart rate (Garmin/ANT)", broadcast) {
                    broadcast = it; puffin.broadcastHr = it; vm.ble.setBroadcastHr(it)
                }
                ToggleRowTC("Record puffin frames to a file", capture) {
                    capture = it; puffin.isCaptureEnabled = it
                }
            }
        }
    }
}

@Composable
private fun ReportReviewDialog(
    previewText: String,
    modeInactive: Boolean,
    onCancel: () -> Unit,
    onShare: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onCancel,
        containerColor = Palette.surfaceOverlay,
        title = { Text("Review before sharing", style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column {
                if (modeInactive) {
                    // #1002: the selected profile's test mode is off, so this bundle carries no capture
                    // for the very thing being reported. Warn plainly, with the fix, BEFORE the user
                    // ships a report a maintainer can't act on. Twin of the Swift review-sheet warning.
                    Text(
                        "Heads up: this test mode is off, so the report has no capture for it. For a " +
                            "useful report, turn the mode on, reproduce the problem while wearing the " +
                            "strap, then report again.",
                        style = NoopType.footnote, color = Palette.statusWarning,
                        modifier = Modifier.padding(bottom = 8.dp),
                    )
                }
                Text(
                    "This is exactly what your report will contain. Nothing leaves this phone until you tap Share.",
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
                Text(
                    previewText.ifBlank { "(nothing to share yet)" },
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    modifier = Modifier
                        .padding(top = 8.dp)
                        .heightIn(max = 320.dp)
                        .verticalScroll(rememberScrollState()),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onShare) { Text("Share", style = NoopType.body, color = Palette.accent) }
        },
        dismissButton = {
            TextButton(onClick = onCancel) { Text("Cancel", style = NoopType.body, color = Palette.textSecondary) }
        },
    )
}

// MARK: - Local section + toggle wrappers (Test Centre owns its own so it never reaches into the private
// SettingsScreen.kt helpers; same NoopCard idiom).

@Composable
private fun SettingsSectionTC(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    blurb: String,
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Overline("Test Centre")
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    androidx.compose.material3.Icon(
                        icon, contentDescription = null, tint = Palette.accent,
                        modifier = Modifier.size(18.dp),
                    )
                    Text(title, style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            Text(blurb, style = NoopType.subhead, color = Palette.textSecondary)
            content()
        }
    }
}

@Composable
private fun ToggleRowTC(title: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(title, style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onCheckedChange, colors = settingsSwitchColors())
    }
}

@Composable
private fun settingsSwitchColors() = SwitchDefaults.colors(
    checkedThumbColor = Palette.surfaceBase,
    checkedTrackColor = Palette.accent,
    uncheckedThumbColor = Palette.textSecondary,
    uncheckedTrackColor = Palette.surfaceInset,
    uncheckedBorderColor = Palette.hairline,
)
