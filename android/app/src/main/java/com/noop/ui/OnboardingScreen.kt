package com.noop.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoGraph
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.ble.WhoopModel
import com.noop.data.ImportSummary
import com.noop.ingest.AppleHealthImporter
import com.noop.ingest.HealthConnectImporter
import com.noop.ingest.WhoopCsvImporter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// MARK: - OnboardingScreen
//
// Android's first-run flow mirrors the macOS OnboardingWizard shape: a paged,
// full-screen sequence that sets expectations, scans/connects to the strap, captures
// the profile values that power zones/calories, imports history, and then hands off to
// the app shell. It uses the same AppViewModel/Repository/BLE client as the app itself.

@Composable
fun OnboardingScreen(viewModel: AppViewModel, onFinished: () -> Unit) {
    val context = LocalContext.current
    val pages = remember { OnboardingPage.entries }
    // rememberSaveable so a config change (rotation, dark-mode, font-scale, locale,
    // multi-window) doesn't recreate the Activity and throw the user back to page 1.
    var pageIndex by rememberSaveable { mutableIntStateOf(0) }
    val page = pages[pageIndex]
    val live by viewModel.live.collectAsStateWithLifecycle()

    // The bonded celebration only makes sense once a strap is actually bonded. Auto-advance to it
    // the moment that happens on the Connect step (mirrors macOS's scan → celebration), and skip
    // it in both directions when nothing is bonded so it never shows a false "You're connected".
    LaunchedEffect(live.bonded) {
        if (live.bonded && page == OnboardingPage.Connect) pageIndex++
    }

    fun complete() {
        // Onboarding deferred the foreground promotion; do it now if a strap is live.
        viewModel.promoteBackgroundConnectionIfActive()
        onFinished()
    }

    // Each permission is requested as the user LEAVES the step that explains it — never on top of
    // the explaining screen, and never at launch: Bluetooth on the "before you connect" step,
    // notifications on the dedicated notifications step. We advance once the prompt is dismissed,
    // whatever the result. blePermissions() is the same shared source of truth Live/Settings use.
    val blePerms = remember { blePermissions() }
    val bleAdvanceLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { pageIndex++ }
    val notifAdvanceLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { pageIndex++ }

    fun advance() {
        when (page) {
            OnboardingPage.Bluetooth -> {
                val granted = blePerms.all {
                    ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
                }
                if (!granted) { bleAdvanceLauncher.launch(blePerms); return }
            }
            OnboardingPage.Connect -> {
                // No strap bonded → skip the celebration and go straight to Profile.
                if (!live.bonded) { pageIndex = pages.indexOf(OnboardingPage.Profile); return }
            }
            OnboardingPage.Notifications -> {
                val needsNotif = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
                    PackageManager.PERMISSION_GRANTED
                if (needsNotif) { notifAdvanceLauncher.launch(Manifest.permission.POST_NOTIFICATIONS); return }
            }
            else -> {}
        }
        pageIndex++
    }

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = Palette.surfaceBase,
    ) {
        // Design Reset: the flow sits on a flat opaque surfaceBase substrate — no scenic starfield
        // hero behind the steps (mirrors the iOS onboarding's clean surfaceBase background). Each
        // step's read-outs live on flat opaque NoopCards over this canvas, not floating on a scene.
        Box(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                // Edge-to-edge (setDecorFitsSystemWindows=false) draws under the system bars,
                // so inset for them here — the onboarding has no Scaffold to do it for us.
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(horizontal = Metrics.screenPadding)
                .padding(top = 16.dp, bottom = 16.dp),
        ) {
            OnboardingTopBar(
                page = pageIndex + 1,
                total = pages.size,
                progress = (pageIndex + 1).toFloat() / pages.size.toFloat(),
            )

            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(top = 44.dp, bottom = 18.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                when (page) {
                    OnboardingPage.Welcome -> WelcomeStep()
                    OnboardingPage.WhatItDoes -> WhatItDoesStep()
                    OnboardingPage.Expectations -> ExpectationsStep()
                    OnboardingPage.Bluetooth -> BluetoothStep()
                    OnboardingPage.Wear -> WearStep()
                    OnboardingPage.Connect -> ConnectStep(viewModel)
                    OnboardingPage.Bonded -> BondedStep(viewModel)
                    OnboardingPage.Profile -> ProfileStep()
                    OnboardingPage.Import -> ImportStep(viewModel)
                    OnboardingPage.Notifications -> NotificationsStep()
                    OnboardingPage.Appearance -> AppearanceStep()
                    OnboardingPage.Done -> DoneStep()
                }
            }

            OnboardingFooter(
                canGoBack = pageIndex > 0,
                cta = page.cta,
                onBack = {
                    var target = pageIndex - 1
                    // Skip the bonded celebration going back when nothing is bonded.
                    if (target >= 0 && pages[target] == OnboardingPage.Bonded && !live.bonded) target--
                    if (target >= 0) pageIndex = target
                },
                onNext = {
                    if (pageIndex == pages.lastIndex) {
                        complete()
                    } else {
                        advance()
                    }
                },
            )
        }
        }
    }
}

private enum class OnboardingPage(val cta: String) {
    Welcome("Begin"),
    WhatItDoes("Continue"),
    Expectations("Continue"),
    Bluetooth("Continue"),
    Wear("Continue"),
    Connect("Continue"),
    Bonded("Continue"),
    Profile("Save & continue"),
    Import("Continue"),
    Notifications("Continue"),
    Appearance("Continue"),
    Done("Enter NOOP");
}

// MARK: - Shell

@Composable
private fun OnboardingTopBar(page: Int, total: Int, progress: Float) {
    val animated by animateFloatAsState(
        targetValue = progress.coerceIn(0f, 1f),
        animationSpec = tween(Motion.durationStandard),
        label = "onboardingProgress",
    )

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Overline("NOOP", color = Palette.accent)
            Spacer(Modifier.weight(1f))
            Text("$page / $total", style = NoopType.captionNumber, color = Palette.textTertiary)
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(3.dp)
                .clip(RoundedCornerShape(50))
                .background(Palette.hairline),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(animated)
                    .height(3.dp)
                    .clip(RoundedCornerShape(50))
                    .background(Palette.accent),
            )
        }
    }
}

@Composable
private fun OnboardingFooter(
    canGoBack: Boolean,
    cta: String,
    onBack: () -> Unit,
    onNext: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = Metrics.gap),
        horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OutlinedButton(
            onClick = onBack,
            enabled = canGoBack,
            colors = ButtonDefaults.outlinedButtonColors(
                contentColor = Palette.textPrimary,
                disabledContentColor = Palette.textTertiary,
            ),
            modifier = Modifier.weight(0.9f),
        ) {
            Text("Back", style = NoopType.subhead)
        }
        Button(
            onClick = onNext,
            colors = ButtonDefaults.buttonColors(
                containerColor = Palette.accent,
                contentColor = Palette.surfaceBase,
            ),
            modifier = Modifier.weight(1.4f),
        ) {
            Text(cta, style = NoopType.headline)
        }
    }
}

@Composable
private fun StepShell(
    title: String? = null,
    subtitle: String? = null,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        if (title != null || subtitle != null) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                title?.let {
                    // Big SF-Rounded hero headline — the onboarding's first-impression voice.
                    Text(
                        it,
                        style = NoopType.display(30f),
                        color = Palette.textPrimary,
                        textAlign = TextAlign.Center,
                    )
                }
                subtitle?.let {
                    Text(
                        it,
                        style = NoopType.body,
                        color = Palette.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
        content()
    }
}

// MARK: - Steps

@Composable
private fun WelcomeStep() {
    StepShell {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 430.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            // The NOOP mark centred on a flat brushed-titanium hero tile (the metallic titanium ramp, a
            // reset token — no gold). Clean and flat: a hairline rim, no bloom.
            Box(contentAlignment = Alignment.Center, modifier = Modifier.size(150.dp)) {
                Box(
                    modifier = Modifier
                        .size(150.dp)
                        .clip(CircleShape)
                        .background(Brush.linearGradient(*Palette.titaniumGradient.toTypedArray()))
                        .border(1.dp, Palette.hairline, CircleShape),
                )
                BrandMark(size = 104.dp)
            }
            Spacer(Modifier.height(18.dp))
            Text(
                "all your data, none of the cloud",
                style = NoopType.title2,
                color = Palette.textSecondary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                "A private window into your recovery, sleep and strain. Read straight from your strap, kept only on this phone.",
                style = NoopType.body,
                color = Palette.textTertiary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun WhatItDoesStep() {
    StepShell(
        title = "What NOOP does",
        subtitle = "Three quiet promises.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            FeatureRow(
                icon = Icons.Filled.AutoGraph,
                tint = Palette.accent,
                title = "See recovery, clearly",
                body = "A calm ring rolls HRV, resting heart rate and sleep into one read on whether to push or rest.",
            )
            FeatureRow(
                icon = Icons.Filled.MonitorHeart,
                tint = Palette.accent,
                title = "Watch your heart, live",
                body = "Connect a WHOOP, a heart-rate strap or a gym machine and watch each beat in real time, with zones that match your profile. Already have history elsewhere? Import it from WHOOP, Apple Health, Oura, Fitbit or Garmin.",
            )
            FeatureRow(
                icon = Icons.Filled.Lock,
                tint = Palette.statusPositive,
                title = "Own your data, offline",
                body = "Everything lives on this phone. No account, no sync, no cloud.",
            )
        }
    }
}

@Composable
private fun ExpectationsStep() {
    StepShell(
        title = "What to expect",
        subtitle = "A few honest words, so nothing is a surprise.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            AppChangelog.expectations.forEach { e ->
                ExpectationCard(e)
            }
        }
    }
}

@Composable
private fun BluetoothStep() {
    StepShell(
        title = "A quick word before you connect",
        subtitle = "NOOP uses Bluetooth to find your strap. When you continue, allow the permission so it can scan.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            IconBadge(icon = Icons.Filled.Bluetooth, tint = Palette.accent, size = 86)
            InfoCard(
                icon = Icons.Filled.Lock,
                tint = Palette.statusPositive,
                title = "Nothing leaves your phone",
                message = "NOOP talks to your strap directly over Bluetooth Low Energy. There's no server in the middle. The connection is local, and so is every reading it pulls in.",
            )
            Checkline("When Android asks, allow Bluetooth so NOOP can scan and connect.")
            Checkline("WHOOP 5.0/MG may need pairing mode the first time, with the official WHOOP app closed.")
        }
    }
}

@Composable
private fun WearStep() {
    StepShell(
        title = "Put your strap on",
        subtitle = "The sensor needs skin contact before data starts to mean anything.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            IconBadge(icon = Icons.Filled.Sensors, tint = Palette.accent, size = 86)
            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Checkline("Wear it snug on your wrist or bicep, sensor against skin.")
                    Checkline("Give it a few minutes of charge if the battery is low.")
                    Checkline("Keep it near this phone while pairing and during the first sync.")
                }
            }
        }
    }
}

@Composable
private fun ConnectStep(viewModel: AppViewModel) {
    val context = LocalContext.current
    val live by viewModel.live.collectAsStateWithLifecycle()
    val selectedModel by viewModel.selectedModel.collectAsStateWithLifecycle()

    val blePerms = remember { blePermissions() }
    // The Scan button goes through the same shared gate as Live/Settings (requests the permission
    // if missing, then connects). Onboarding connects without promoting the foreground service —
    // OnboardingScreen promotes it on completion. See AppViewModel.connect(promoteService).
    val requestConnect = rememberRequestScan { viewModel.connect(promoteService = false) }
    var autoConnectStarted by rememberSaveable { mutableStateOf(false) }

    val bleGranted = blePerms.all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

    LaunchedEffect(Unit) {
        if (!autoConnectStarted && !live.bonded && !live.connected && !live.scanning) {
            autoConnectStarted = true
            // Only auto-scan if permission is already in hand (granted on the Bluetooth step). We
            // never raise the OS prompt here — that would land on top of this step's own content.
            if (bleGranted) viewModel.connect(promoteService = false)
        }
    }

    StepShell(
        title = "Find your strap",
        subtitle = when {
            live.bonded -> "Bonded. You can keep going."
            bleGranted -> "NOOP starts looking as soon as this step appears. You can keep going while it bonds."
            else -> "Allow Bluetooth and tap Scan to find your strap, or keep going and connect later."
        },
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            IconBadge(
                icon = if (live.bonded) Icons.Filled.CheckCircle else Icons.Filled.Bluetooth,
                tint = if (live.bonded) Palette.statusPositive else Palette.accent,
                size = 92,
            )

            val (label, tone, pulsing) = when {
                live.encryptedBond -> Triple("Bonded · streaming", StrandTone.Positive, true)
                live.bonded -> Triple("Live HR · not fully paired", StrandTone.Warning, true)
                live.connected -> Triple("Connected · pairing", StrandTone.Warning, true)
                live.scanning -> Triple("Searching", StrandTone.Accent, true)
                else -> Triple("Ready to scan", StrandTone.Neutral, false)
            }
            StatePill(label, tone = tone, pulsing = pulsing, showsDot = true)

            live.statusNote?.let {
                Text(
                    it,
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }

            if (!live.bonded) {
                NoopCard(padding = 16.dp) {
                    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Text("Strap", style = NoopType.footnote, color = Palette.textSecondary)
                            SegmentedPillControl(
                                items = WhoopModel.entries.toList(),
                                selection = selectedModel,
                                label = { it.displayName },
                                onSelect = {
                                    viewModel.setSelectedModel(it)
                                    if (!live.bonded) {
                                        viewModel.disconnect()
                                        requestConnect()
                                    }
                                },
                                modifier = Modifier.weight(1f),
                            )
                        }

                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                            Button(
                                onClick = { requestConnect() },
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = Palette.accent,
                                    contentColor = Palette.surfaceBase,
                                ),
                                modifier = Modifier.weight(1f),
                            ) {
                                Icon(Icons.Filled.Bluetooth, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(if (live.connected || live.scanning) "Re-scan" else "Scan again", style = NoopType.body)
                            }
                            OutlinedButton(
                                onClick = { viewModel.disconnect() },
                                enabled = live.connected || live.scanning,
                                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.statusCritical),
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("Stop", style = NoopType.body)
                            }
                        }
                    }
                }
            }

            InfoCard(
                icon = Icons.Filled.Lock,
                tint = Palette.statusPositive,
                title = "This can run while you finish setup",
                message = "If the strap is nearby, NOOP will keep the BLE link alive in the background. You can continue through profile and import while it bonds.",
            )

            // WHOOP is NOOP's primary band, so onboarding leads with it — but it isn't required.
            // Make that obvious so a non-WHOOP user doesn't feel stuck on this step (#415-adjacent):
            // they can continue now and pair a heart-rate strap or import data afterwards.
            if (!live.bonded) {
                Text(
                    "No WHOOP? You can still continue. Pair a heart-rate strap (Polar, Wahoo, Coospo, Garmin HRM…) " +
                        "or a gym machine under Devices, or import from WHOOP, Apple Health, Oura, Fitbit, Garmin " +
                        "and more under Data Sources. You can do either any time.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

// A short celebration once the strap bonds — the Connect step auto-advances here on bond, and
// the nav skips it entirely when nothing is bonded (mirrors the macOS scan → bonded moment).
@Composable
private fun BondedStep(viewModel: AppViewModel) {
    val live by viewModel.live.collectAsStateWithLifecycle()
    StepShell {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 430.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Box(contentAlignment = Alignment.Center) {
                RecoveryRing(score = 100.0, diameter = 200.dp, lineWidth = 14.dp, showsLabel = false)
                Icon(
                    Icons.Filled.Check,
                    contentDescription = null,
                    tint = Palette.statusPositive,
                    modifier = Modifier.size(54.dp),
                )
            }
            Spacer(Modifier.height(24.dp))
            Text(
                "You're connected.",
                style = NoopType.title1,
                color = Palette.textPrimary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(10.dp))
            Text(
                live.batteryPct?.let { "Your strap is bonded · ${it.toInt()}% battery." }
                    ?: "Your strap is bonded and ready to stream.",
                style = NoopType.body,
                color = Palette.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun ProfileStep() {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context.applicationContext) }
    // Imperial/Metric display preference (D#103). The stored profile is always SI; the steppers keep
    // operating in SI and only the DISPLAYED value re-labels to lb / ft-in. Held in remembered state
    // (#781) so the Units control below can flip it live. SharedPreferences isn't reactive, so the
    // picker writes through to NoopPrefs AND updates this state to re-render the Weight/Height labels.
    var unitSystem by remember { mutableStateOf(UnitPrefs.system(context)) }
    var rev by remember { mutableIntStateOf(0) }
    fun mutate(block: () -> Unit) {
        block()
        rev++
    }
    @Suppress("UNUSED_VARIABLE") val tick = rev

    StepShell(
        title = "About you",
        subtitle = "So your zones, calories and on-device scoring start from the right numbers.",
    ) {
        NoopCard(padding = 18.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                ProfileFieldRow(label = "Age") {
                    StepperField(
                        value = "${profile.age}",
                        unit = "yrs",
                        accessibility = "Age, ${profile.age} years",
                        onMinus = { mutate { profile.age -= 1 } },
                        onPlus = { mutate { profile.age += 1 } },
                    )
                }
                ThinDivider()
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Sex", color = Palette.textTertiary)
                    SegmentedPillControl(
                        items = ONBOARDING_SEX_OPTIONS,
                        selection = ONBOARDING_SEX_OPTIONS.firstOrNull { it.tag == profile.sex }
                            ?: ONBOARDING_SEX_OPTIONS[0],
                        label = { it.label },
                        onSelect = { mutate { profile.sex = it.tag } },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                ThinDivider()
                // Units control (#781). Onboarding read `unitSystem` for the Weight/Height display but
                // had no way to set it, so US users were locked to kg/cm until they found Settings →
                // Units. Mirror the Sex picker idiom; the stored profile stays SI either way, only the
                // displayed labels re-format (lb / ft-in). Same key Settings → Units writes.
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Units", color = Palette.textTertiary)
                    SegmentedPillControl(
                        items = listOf(UnitSystem.METRIC, UnitSystem.IMPERIAL),
                        selection = unitSystem,
                        label = { if (it == UnitSystem.METRIC) "Metric" else "Imperial" },
                        onSelect = {
                            unitSystem = it
                            NoopPrefs.setUnitSystem(context, it)
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                ThinDivider()
                ProfileFieldRow(label = "Weight") {
                    StepperField(
                        // Full re-labelled string (e.g. "74.5 kg" / "164.2 lb"); unit folded into value.
                        value = UnitFormatter.massFromKilograms(profile.weightKg, unitSystem),
                        accessibility = "Weight",
                        onMinus = { mutate { profile.weightKg = (profile.weightKg - 0.5).coerceIn(30.0, 250.0) } },
                        onPlus = { mutate { profile.weightKg = (profile.weightKg + 0.5).coerceIn(30.0, 250.0) } },
                    )
                }
                ThinDivider()
                ProfileFieldRow(label = "Height") {
                    StepperField(
                        value = UnitFormatter.heightFromCentimeters(profile.heightCm, unitSystem),
                        accessibility = "Height",
                        onMinus = { mutate { profile.heightCm = (profile.heightCm - 1).coerceIn(120.0, 230.0) } },
                        onPlus = { mutate { profile.heightCm = (profile.heightCm + 1).coerceIn(120.0, 230.0) } },
                    )
                }
            }
        }

        Row(
            modifier = Modifier.semantics { contentDescription = "Estimated max heart rate ${profile.hrMax} bpm" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Filled.FavoriteBorder, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(17.dp))
            Text(
                "Estimated max heart rate · ${profile.hrMax} bpm",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun ImportStep(viewModel: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    // busy stays transient: a config change / process death cancels the import coroutine,
    // so a persisted busy=true would strand the buttons disabled with nothing running.
    var busy by remember { mutableStateOf(false) }
    var status by rememberSaveable { mutableStateOf<String?>(null) }

    fun runImport(block: suspend () -> ImportSummary) {
        busy = true
        status = "Importing…"
        scope.launch {
            val summary = withContext(Dispatchers.IO) {
                runCatching { block() }.getOrElse { ImportSummary.failure("Import", it.message ?: "failed") }
            }
            // Import & Data Ingest test mode (Test Centre): emit the parser / per-stage / day-delta trace,
            // tagged IMPORT, iff the mode is on. Gated zero-cost when off; shared with the Data Sources flow.
            emitImportTrace(context, viewModel, summary)
            busy = false
            status = summary.message
            Toast.makeText(context, summary.message, Toast.LENGTH_LONG).show()
        }
    }

    val whoopImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { WhoopCsvImporter.importZip(context, uri, viewModel.repo) } }

    val appleImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { AppleHealthImporter.importExport(context, uri, viewModel.repo) } }

    val hcPermissionLauncher = rememberLauncherForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) { granted ->
        if (granted.any { it in HealthConnectImporter.PERMISSIONS }) {
            runImport { HealthConnectImporter.import(context, viewModel.repo, ProfileStore.from(context).heightCm) }
        } else {
            val message = "Health Connect access not granted."
            status = message
            Toast.makeText(context, message, Toast.LENGTH_LONG).show()
        }
    }

    val healthConnectAvailable = remember {
        HealthConnectImporter.sdkStatus(context) == HealthConnectClient.SDK_AVAILABLE
    }

    fun startHealthConnect() {
        scope.launch {
            val granted = runCatching {
                HealthConnectImporter.client(context).permissionController.getGrantedPermissions()
            }.getOrDefault(emptySet())
            if (granted.any { it in HealthConnectImporter.PERMISSIONS }) {
                runImport { HealthConnectImporter.import(context, viewModel.repo, ProfileStore.from(context).heightCm) }
            } else {
                hcPermissionLauncher.launch(HealthConnectImporter.PERMISSIONS)
            }
        }
    }

    StepShell(
        title = "Bring your history",
        subtitle = "Optional: import now, or skip and return to Data Sources later.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            IconBadge(icon = Icons.Filled.Storage, tint = Palette.accent, size = 82)
            InfoCard(
                icon = Icons.Filled.AutoGraph,
                tint = Palette.accent,
                title = "History fills the dashboard immediately",
                message = "A WHOOP export backfills recovery, strain, sleep and workouts. Health Connect can add steps, HR, HRV, sleep and weight from Android sources.",
            )

            NoopCard(padding = 16.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OnboardingActionButton(
                        label = "Import WHOOP export (.zip)",
                        icon = Icons.Filled.FileUpload,
                        enabled = !busy,
                    ) { whoopImportLauncher.launch(arrayOf("*/*")) }
                    OnboardingActionButton(
                        label = "Import from Health Connect",
                        icon = Icons.Filled.MonitorHeart,
                        enabled = !busy && healthConnectAvailable,
                    ) { startHealthConnect() }
                    OnboardingActionButton(
                        label = "Import Apple Health export",
                        icon = Icons.Filled.FavoriteBorder,
                        enabled = !busy,
                    ) { appleImportLauncher.launch(arrayOf("*/*")) }
                }
            }

            if (!healthConnectAvailable) {
                Text(
                    "Health Connect is not available on this device.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                )
            }
            status?.let {
                Text(
                    it,
                    style = NoopType.footnote,
                    color = if (busy) Palette.accent else Palette.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun NotificationsStep() {
    StepShell(
        title = "Stay in the loop",
        subtitle = "NOOP keeps your strap connected in the background. When you continue, allow notifications so it can show that link and reach your wrist.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            IconBadge(icon = Icons.Filled.Notifications, tint = Palette.accent, size = 86)
            InfoCard(
                icon = Icons.Filled.Bluetooth,
                tint = Palette.statusPositive,
                title = "A quiet, ongoing status",
                message = "NOOP holds the Bluetooth link open in the background so your data stays current. One low-priority notification shows it's connected. Nothing noisy.",
            )
            Checkline("Wrist alerts (strain nudges and your smart alarm) arrive as notifications too.")
            Checkline("When Android asks, allow notifications so NOOP can keep you informed.")
        }
    }
}

// A late step that tells new users NOOP's look is theirs to set — the same System / Light / Dark
// choice that lives in Settings → Appearance, with a live preview. Writing the choice flips the whole
// app immediately (AppearancePrefs.mode is snapshot state; Palette re-resolves live), so the picker
// IS the preview — and two mini swatches show both the warm-paper Light and dark blue-grey looks.
@Composable
private fun AppearanceStep() {
    val context = LocalContext.current
    var mode by remember { mutableStateOf(AppearancePrefs.mode) }

    StepShell(
        title = "Make it yours",
        subtitle = "NOOP follows your system by default, or pick Light or Dark. You can change this any time in Settings → Appearance.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            // Two mini look-swatches so the choice is concrete: warm-paper Light and dark blue-grey.
            // The one matching the live theme carries an accent (blue) rim; System shows whichever
            // the phone is currently on.
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
            ) {
                ThemeSwatch(
                    title = "Light",
                    tokens = LightTokens,
                    selected = Palette.isLight,
                    modifier = Modifier.weight(1f),
                )
                ThemeSwatch(
                    title = "Dark",
                    tokens = DarkTokens,
                    selected = !Palette.isLight,
                    modifier = Modifier.weight(1f),
                )
            }

            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    ProfileFieldRow(label = "Theme") {
                        SegmentedPillControl(
                            items = listOf(AppearanceMode.SYSTEM, AppearanceMode.LIGHT, AppearanceMode.DARK),
                            selection = mode,
                            label = { it.label },
                            onSelect = {
                                mode = it
                                // Persist + flip live — the rest of the onboarding (and the app) re-themes
                                // instantly, so the user sees their choice land before tapping Continue.
                                AppearancePrefs.set(context, it)
                            },
                        )
                    }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            Icons.Filled.Palette,
                            contentDescription = null,
                            tint = Palette.accent,
                            modifier = Modifier.size(17.dp),
                        )
                        Text(
                            when (mode) {
                                AppearanceMode.SYSTEM -> "Following your phone's light/dark setting."
                                AppearanceMode.LIGHT -> "Deep blue accent on warm paper."
                                AppearanceMode.DARK -> "Deep blue accent on a dark blue-grey canvas."
                            },
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                }
            }
        }
    }
}

/** A small fixed-palette look-swatch (a surface chip + accent ring + hairline) so the user can see a
 *  theme without switching to it. Uses the passed token set directly (not the live Palette) so Light
 *  always renders Light and Dark always renders Dark, whatever the current theme. */
@Composable
private fun ThemeSwatch(
    title: String,
    tokens: PaletteTokens,
    selected: Boolean,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(76.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(tokens.surfaceBase)
                .border(
                    width = if (selected) 2.dp else 1.dp,
                    color = if (selected) Palette.accent else tokens.hairline,
                    shape = RoundedCornerShape(14.dp),
                )
                .padding(12.dp),
            contentAlignment = Alignment.CenterStart,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                // A mini score bead in the live accent (reset blue — gold is killed), on the theme's
                // raised card. Uses the live Palette.accent, not tokens.gold (whose LIGHT value is still
                // the retired gold), so the bead reads as the reset accent on both swatches.
                Box(
                    modifier = Modifier
                        .size(26.dp)
                        .clip(CircleShape)
                        .background(Palette.accent),
                )
                Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Box(
                        modifier = Modifier
                            .width(46.dp)
                            .height(7.dp)
                            .clip(RoundedCornerShape(50))
                            .background(tokens.surfaceRaised),
                    )
                    Box(
                        modifier = Modifier
                            .width(32.dp)
                            .height(7.dp)
                            .clip(RoundedCornerShape(50))
                            .background(tokens.hairlineStrong),
                    )
                }
            }
        }
        Text(
            title,
            style = NoopType.footnote,
            color = if (selected) Palette.accent else Palette.textTertiary,
        )
    }
}

@Composable
private fun DoneStep() {
    StepShell {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 430.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            IconBadge(icon = Icons.Filled.CheckCircle, tint = Palette.statusPositive, size = 100)
            Spacer(Modifier.height(22.dp))
            Text(
                "Your thread starts here.",
                style = NoopType.title1,
                color = Palette.textPrimary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(10.dp))
            Text(
                "Every beat, every night, every day, woven into one quiet picture of you. Welcome to NOOP.",
                style = NoopType.body,
                color = Palette.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

// MARK: - Pieces

@Composable
private fun FeatureRow(icon: ImageVector, tint: Color, title: String, body: String) {
    NoopCard(padding = 16.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.Top,
        ) {
            IconSquare(icon = icon, tint = tint)
            Column(verticalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.weight(1f)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(body, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun ExpectationCard(e: AppChangelog.Expectation) {
    NoopCard(padding = 14.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(e.icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(22.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(e.title, style = NoopType.headline, color = Palette.textPrimary)
                Text(e.body, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun InfoCard(icon: ImageVector, tint: Color, title: String, message: String) {
    NoopCard(padding = 16.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.Top,
        ) {
            IconSquare(icon = icon, tint = tint)
            Column(verticalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.weight(1f)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(message, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun OnboardingActionButton(
    label: String,
    icon: ImageVector,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth(),
        colors = ButtonDefaults.buttonColors(
            containerColor = Palette.accent,
            contentColor = Palette.surfaceBase,
            disabledContainerColor = Palette.surfaceInset,
            disabledContentColor = Palette.textTertiary,
        ),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, style = NoopType.body)
    }
}

@Composable
private fun Checkline(text: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Check, contentDescription = null, tint = Palette.statusPositive, modifier = Modifier.size(17.dp))
        Text(text, style = NoopType.subhead, color = Palette.textSecondary, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun IconBadge(icon: ImageVector, tint: Color, size: Int) {
    Box(
        modifier = Modifier
            .size(size.dp)
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.13f))
            .border(1.dp, tint.copy(alpha = 0.28f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size((size * 0.42f).dp))
    }
}

@Composable
private fun IconSquare(icon: ImageVector, tint: Color) {
    Box(
        modifier = Modifier
            .size(42.dp)
            .clip(RoundedCornerShape(11.dp))
            .background(tint.copy(alpha = 0.13f))
            .border(1.dp, tint.copy(alpha = 0.22f), RoundedCornerShape(11.dp)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
    }
}

/** Label-left, control-right form row — mirrors Settings' FormRow so profile editors match. */
@Composable
private fun ProfileFieldRow(label: String, control: @Composable () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(label, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        control()
    }
}

@Composable
private fun ThinDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}

private data class OnboardingSexOption(val tag: String, val label: String)

private val ONBOARDING_SEX_OPTIONS = listOf(
    OnboardingSexOption("male", "Male"),
    OnboardingSexOption("female", "Female"),
    OnboardingSexOption("nonbinary", "Other"),
)
