package com.noop.ui

import android.content.Intent
import android.net.Uri
import android.text.format.DateUtils
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.Restore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.data.DataBackup
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Backup & Sync (Phase 1 - folder). Apple mirror of `BackupSyncView`: pick a folder, turn on the
 * opt-in daily auto-backup, back up now, or restore. Snapshots are the existing `.noopbak` whole-DB
 * format ([DataBackup]). Point the folder at a Google Drive / Dropbox sync app for off-device backup
 * with no in-app cloud account.
 *
 * Must-fixes baked in here:
 *  1. Restore lists the snapshots in the CHOSEN folder (newest-first) and lets the user pick one,
 *     rather than re-prompting with an unrelated document picker. A tightened file fallback exists
 *     only for folders we can't enumerate / legacy files.
 *  2. An explicit in-app confirm dialog fires before any destructive restore call.
 *  3. The file-fallback picker is tightened off the all-files wildcard to the backup MIME types, and
 *     the live [DataBackup.importFrom] now also rejects a foreign-but-valid SQLite (Mac/GRDB or other-app DB).
 */
@Composable
fun BackupSyncScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var treeUri by remember { mutableStateOf(BackupSyncPrefs.treeUri(context)) }
    var auto by remember { mutableStateOf(BackupSyncPrefs.autoEnabled(context)) }
    var lastMs by remember { mutableStateOf(BackupSyncPrefs.lastBackupMs(context)) }
    var busy by remember { mutableStateOf(false) }

    // Restore-from-folder sheet state: the listed snapshots, and the one pending confirmation.
    var snapshots by remember { mutableStateOf<List<BackupSync.SnapshotDoc>>(emptyList()) }
    var showSnapshotPicker by remember { mutableStateOf(false) }
    var pendingRestore by remember { mutableStateOf<Pair<String, Uri>?>(null) }

    // Runs the actual destructive restore for a chosen backup Uri, off the main thread.
    fun runRestore(uri: Uri) {
        busy = true
        scope.launch {
            val r = withContext(Dispatchers.IO) { DataBackup.importFrom(context, uri) }
            busy = false
            val msg = when (r) {
                is DataBackup.ImportResult.NeedsRestart ->
                    "Restored. Fully close and reopen NOOP to load it."
                is DataBackup.ImportResult.Failed -> r.message
            }
            Toast.makeText(context, msg, Toast.LENGTH_LONG).show()
        }
    }

    val pickFolder = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocumentTree(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        runCatching {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
        BackupSyncPrefs.setTreeUri(context, uri)
        treeUri = uri
        runCatching { BackupSync.reschedule(context) }
    }

    // Must-fix #1 + #3: the FILE fallback is tightened to the backup MIME types (was `*/*`). Used only
    // when the chosen folder holds no snapshots, or to restore a one-off file from elsewhere. The chosen
    // file still passes through importFrom's full validation (magic + Room/GRDB-origin) and the same
    // confirm dialog before it overwrites anything.
    val pickRestoreFile = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        pendingRestore = "the selected file" to uri
    }

    LazyScreenScaffold(
        title = "Backup & Sync",
        subtitle = "Save a full backup to a folder you choose - point it at Google Drive / Dropbox for off-device sync.",
    ) {
        // 1 · Destination folder
        item {
            NoopCard(padding = 20.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Backup folder", style = NoopType.headline, color = Palette.textPrimary)
                    Text(
                        treeUri?.let { "Saving to: ${folderLabel(it)}" }
                            ?: "No folder chosen yet. Pick one your cloud app already syncs, or any local folder.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                    Text(
                        "Tip: a desktop Drive / Dropbox app auto-syncs a chosen folder. On the phone, save to a " +
                            "folder a sync app (e.g. FolderSync / Autosync) keeps in your cloud.",
                        style = NoopType.caption, color = Palette.accent,
                    )
                    NoopButton(
                        text = if (treeUri == null) "Choose folder" else "Change folder",
                        leadingIcon = Icons.Filled.FolderOpen,
                        kind = NoopButtonKind.Secondary,
                        enabled = !busy,
                        onClick = { pickFolder.launch(null) },
                    )
                }
            }
        }

        // 2 · Auto-backup + back up now
        item {
            NoopCard(padding = 20.dp, tint = if (auto && treeUri != null) Palette.accent else null) {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text("Daily auto-backup", style = NoopType.body, color = Palette.textPrimary)
                            Text(
                                "Writes a fresh backup to your folder about once a day (keeps the latest " +
                                    "${BackupSyncPrefs.keepCount(context)}). Off by default - flip it on if you want it.",
                                style = NoopType.footnote, color = Palette.textTertiary,
                            )
                        }
                        Spacer(Modifier.width(16.dp))
                        Switch(
                            checked = auto,
                            enabled = treeUri != null && !busy,
                            onCheckedChange = {
                                auto = it
                                BackupSyncPrefs.setAutoEnabled(context, it)
                                runCatching { BackupSync.reschedule(context) }
                            },
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Palette.surfaceBase,
                                checkedTrackColor = Palette.accent,
                                uncheckedThumbColor = Palette.textSecondary,
                                uncheckedTrackColor = Palette.surfaceInset,
                                uncheckedBorderColor = Palette.hairline,
                            ),
                        )
                    }
                    Text(
                        if (lastMs > 0L) {
                            "Last backup: ${DateUtils.getRelativeTimeSpanString(lastMs)}"
                        } else {
                            "No backup yet."
                        },
                        style = NoopType.caption, color = Palette.textTertiary,
                    )
                    NoopButton(
                        text = if (busy) "Working…" else "Back up now",
                        leadingIcon = Icons.Filled.CloudUpload,
                        fullWidth = true,
                        enabled = treeUri != null && !busy,
                        onClick = {
                            busy = true
                            scope.launch {
                                val ok = withContext(Dispatchers.IO) { BackupSync.backupNow(context) }
                                lastMs = BackupSyncPrefs.lastBackupMs(context)
                                busy = false
                                Toast.makeText(
                                    context,
                                    if (ok) {
                                        "Backed up to your folder."
                                    } else {
                                        "Backup failed - re-pick the folder and try again."
                                    },
                                    Toast.LENGTH_LONG,
                                ).show()
                            }
                        },
                    )
                }
            }
        }

        // 3 · Restore (must-fix #1: from the chosen folder, newest-first)
        item {
            NoopCard(padding = 20.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Restore", style = NoopType.headline, color = Palette.textPrimary)
                    Text(
                        "Replace this device's data with one of your backups. This overwrites current data, " +
                            "so back up first if unsure.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                    NoopButton(
                        text = "Restore from a backup…",
                        leadingIcon = Icons.Filled.Restore,
                        kind = NoopButtonKind.Secondary,
                        enabled = !busy,
                        onClick = {
                            val tree = treeUri
                            if (tree == null) {
                                // No folder set: fall back to the tightened file picker.
                                pickRestoreFile.launch(RESTORE_MIME_TYPES)
                            } else {
                                scope.launch {
                                    val found = withContext(Dispatchers.IO) {
                                        runCatching { BackupSync.listSnapshotDocs(context, tree) }
                                            .getOrDefault(emptyList())
                                    }
                                    if (found.isEmpty()) {
                                        // Folder has no snapshots we wrote - point at a file instead.
                                        pickRestoreFile.launch(RESTORE_MIME_TYPES)
                                    } else {
                                        snapshots = found
                                        showSnapshotPicker = true
                                    }
                                }
                            }
                        },
                    )
                }
            }
        }
    }

    // Must-fix #1: the snapshot picker - the folder's backups, newest-first.
    if (showSnapshotPicker) {
        AlertDialog(
            onDismissRequest = { showSnapshotPicker = false },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text("Choose a backup", style = NoopType.title2, color = Palette.textPrimary)
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        "Newest first. Restoring replaces this device's data.",
                        style = NoopType.footnote, color = Palette.textSecondary,
                    )
                    snapshots.forEach { snap ->
                        // Label + confirmation come from the resolved timeMs carried through from
                        // listSnapshotDocs, so a hand-named / date-only backup still shows a friendly date
                        // (its file-modification date) instead of the raw filename - parity with Swift. Only
                        // when the date is genuinely unknown (timeMs == 0) do we fall back to the name.
                        val whenLabel = if (snap.timeMs > 0L) {
                            DateUtils.getRelativeTimeSpanString(snap.timeMs).toString()
                        } else {
                            snap.name
                        }
                        Text(
                            text = whenLabel,
                            style = NoopType.body,
                            color = Palette.textPrimary,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    showSnapshotPicker = false
                                    pendingRestore = if (snap.timeMs > 0L) {
                                        "the backup from $whenLabel"
                                    } else {
                                        snap.name
                                    } to snap.uri
                                }
                                .padding(vertical = 10.dp),
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showSnapshotPicker = false }) {
                    Text("Cancel", style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }

    // Must-fix #2: explicit in-app confirm BEFORE any destructive restore call, on every restore path.
    pendingRestore?.let { (label, uri) ->
        AlertDialog(
            onDismissRequest = { pendingRestore = null },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text("Replace all current data?", style = NoopType.title2, color = Palette.textPrimary)
            },
            text = {
                Text(
                    "Replace all current data with $label? This cannot be undone.",
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    pendingRestore = null
                    runRestore(uri)
                }) {
                    Text("Replace", style = NoopType.body, color = Palette.statusCritical)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingRestore = null }) {
                    Text("Cancel", style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }
}

/**
 * Must-fix #3: the restore file fallback is tightened off the all-files wildcard to the backup
 * container MIME types: the .noopbak ZIP (octet-stream / zip) and a legacy plain SQLite. Anything that
 * slips through still meets importFrom's magic-byte + Room/GRDB-origin validation before it can touch
 * the live DB.
 */
private val RESTORE_MIME_TYPES = arrayOf(
    "application/octet-stream",
    "application/zip",
    "application/x-sqlite3",
)

/** A short, human label for a SAF tree Uri (the part after the volume colon). */
private fun folderLabel(treeUri: Uri): String {
    val seg = treeUri.lastPathSegment ?: return "selected folder"
    return seg.substringAfterLast(':').ifBlank { seg }
}
