package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.draw.clip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.HrZones
import com.noop.ble.StandardHrSource
import kotlinx.coroutines.delay

/**
 * Live workout mode (#238) — the in-exercise screen: a big live heart rate, the current HR zone,
 * elapsed time, and live effort building, all from the SAME live feed and scorers the rest of the
 * app uses (no invented numbers). Shown full-screen while a manual workout is active, entered from
 * the Start-workout control. End stops the workout and dismisses.
 *
 * Live HR is the smoothed [AppViewModel.bpm]; the zone is derived from the user's HR-max via the
 * shared [HrZones] model; elapsed time ticks from the workout's start; effort is the running
 * [AppViewModel.ActiveWorkout.liveStrain] (StrainScorer over the captured window). Keeps the realtime
 * HR stream on while visible, ref-counted in the ViewModel so it hands off cleanly with Live/Health.
 */
@Composable
fun LiveWorkoutScreen(vm: AppViewModel, onClose: () -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context.applicationContext) }
    // Effort display scale (#268) — routes the live Effort read-out so it matches every other surface.
    val effortScale = UnitPrefs.effortScale(context)
    val bpm by vm.bpm.collectAsStateWithLifecycle()
    val activeWorkout by vm.activeWorkout.collectAsStateWithLifecycle()
    // Additive: instantaneous speed/cadence/power from a connected standard fitness sensor (RSC/CSC/CPS),
    // read ALONGSIDE HR by the SourceCoordinator's isolated StandardHrSource. Empty (all-null) when no such
    // sensor is feeding, so the readout below hides entirely — a plain HR-only workout looks unchanged. HR
    // / zone / effort above are untouched.
    val sensor by remember(context) {
        (context.applicationContext as com.noop.NoopApplication).sourceCoordinator.sensorMetrics
    }.collectAsStateWithLifecycle()

    // Keep the live HR stream on for the duration of the workout screen (ref-counted with Live/Health).
    DisposableEffect(Unit) {
        vm.requestRealtimeHr()
        onDispose { vm.releaseRealtimeHr() }
    }

    // Keep the screen awake while recording (#703). Opt-in, default off; the toggle lives in Settings.
    // Read the same pref key the iOS @AppStorage uses ("workoutKeepScreenOn") and flag the view's window
    // only while this screen is up, clearing it on the way out so normal screen-timeout resumes. Mirrors
    // iOS calling ScreenIdle.keepAwake(true) on appear and false on disappear.
    val view = LocalView.current
    DisposableEffect(Unit) {
        val on = NoopPrefs.of(context).getBoolean("workoutKeepScreenOn", false)
        if (on) view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }

    val w = activeWorkout
    // If the workout ended elsewhere (e.g. process restart cleared it), close out.
    LaunchedEffect(w == null) { if (w == null) onClose() }
    if (w == null) return

    val zoneSet = remember(profile.hrMax) { HrZones.zones(maxHR = profile.hrMax.toDouble()) }
    val zone = bpm?.let { zoneSet.zoneNumber(it.toDouble()) } ?: 0

    var nowMs by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(w.startMs) {
        while (true) { nowMs = System.currentTimeMillis(); delay(1000) }
    }
    val elapsedS = ((nowMs - w.startMs) / 1000).coerceAtLeast(0)

    // A scenic Effort-tinted backdrop behind the whole in-exercise screen — the live workout reads as
    // an Effort-world hero, not a flat panel.
    Box(modifier = Modifier.fillMaxSize().background(Palette.surfaceBase)) {
        ScenicHeroBackground(modifier = Modifier.matchParentSize(), domain = DomainTheme.Effort)
        // #845: the in-exercise content is fixed-height (HR hero + effort gauge + zone rail + stat row +
        // End button). On a tall, content-dense screen it ran PAST the available height: the old layout was a
        // plain fillMaxSize Column with a weighted Spacer pushing End down, so when content overflowed the
        // Spacer collapsed to nothing and the bottom Avg/Peak/Effort stat row got squeezed against the edge
        // with its values clipped. Make the column scrollable so the whole stack stays fully readable when it
        // doesn't fit, and add navigationBarsPadding so the bottom row/button clear the Android 15 gesture
        // inset. When everything DOES fit there's nothing to scroll, so it looks unchanged.
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(28.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // Header — sport + elapsed clock.
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Overline("Recording workout", color = Palette.effortColor)
                    Text(w.sport.name, style = NoopType.title1, color = Palette.textPrimary)
                }
                Text(
                    String.format("%d:%02d", elapsedS / 60, elapsedS % 60),
                    style = NoopType.number(34f), color = Palette.textPrimary,
                )
            }

            // The hero — big live HR, tinted to the current zone.
            HeroHeartRate(bpm = bpm, zone = zone)

            // The accumulating Effort on the shared layered StrainGauge — liveStrain is on NOOP's 0–100
            // Effort axis, mapped to the gauge's 0–21 span (mirrors the Today effort hero). Display-only.
            EffortGauge(liveStrain = w.liveStrain, effortScale = effortScale)

            // Zone rail — five segments, the active one lit.
            ZoneRail(zone = zone, zoneSet = zoneSet)

            // Live stats grid — avg / peak / effort, from the captured window.
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
                StatTile(modifier = Modifier.weight(1f), label = "Avg", value = if (w.avgHr > 0) "${w.avgHr}" else "—",
                    accent = if (w.avgHr > 0) Palette.metricRose else Palette.textPrimary)
                StatTile(modifier = Modifier.weight(1f), label = "Peak", value = if (w.peakHr > 0) "${w.peakHr}" else "—",
                    accent = if (w.peakHr > 0) Palette.metricRose else Palette.textPrimary)
                StatTile(modifier = Modifier.weight(1f), label = "Effort", value = UnitFormatter.effortDisplay(w.liveStrain, effortScale),
                    accent = Palette.strainColor(w.liveStrain))
            }

            // Additive sensor readout — only renders when a connected standard fitness sensor is feeding.
            SensorRow(sensor)

            // #845: a fixed gap before End instead of a weighted Spacer. A weight needs a bounded height to
            // share out, but the column is now scrollable (unbounded), so a weighted Spacer can't size and
            // the End button would no longer be separated from the stats. A constant gap keeps the spacing
            // and the button stays reachable by scrolling when the content overflows.
            Spacer(Modifier.height(12.dp))

            Button(
                onClick = { vm.endWorkout(); onClose() },
                modifier = Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(vertical = 14.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Palette.statusCritical, contentColor = Palette.surfaceBase,
                ),
            ) { Text("End workout", style = NoopType.headline) }
        }
    }
}

/**
 * Additive readout for a connected standard fitness sensor (a footpod / bike speed-cadence sensor / power
 * meter) feeding RSC/CSC/CPS ALONGSIDE heart rate. Only the fields the sensor actually sent render — each
 * tile is dropped when its value is absent, and the whole row is hidden when nothing is present, so a plain
 * HR-only workout looks exactly as before. Honest units: speed km/h, cadence per-minute (steps for running
 * / rpm for cycling), power watts. Reuses the same metric tile as the HR stats grid; tinted with the Effort
 * world so it reads as part of the hero. Nothing here touches HR / zone / effort.
 */
@Composable
private fun SensorRow(sensor: StandardHrSource.SensorMetrics) {
    val speed = StandardHrSource.formatSpeedKmh(sensor.speedKmh)
    val cadence = StandardHrSource.formatCadence(sensor.cadence)
    val power = StandardHrSource.formatPowerWatts(sensor.powerWatts)
    if (speed == null && cadence == null && power == null) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Overline("Sensor")
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
            if (speed != null) {
                StatTile(modifier = Modifier.weight(1f), label = "Speed", value = "$speed km/h", accent = Palette.effortColor)
            }
            if (cadence != null) {
                StatTile(modifier = Modifier.weight(1f), label = "Cadence", value = "$cadence/min", accent = Palette.effortColor)
            }
            if (power != null) {
                StatTile(modifier = Modifier.weight(1f), label = "Power", value = "$power W", accent = Palette.effortColor)
            }
        }
    }
}

@Composable
private fun EffortGauge(liveStrain: Double, effortScale: EffortScale) {
    NoopCard(padding = 18.dp, tint = Palette.effortColor) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Overline("Effort building", color = Palette.effortColor)
            StrainGauge(
                strain = UnitFormatter.effortValue(liveStrain, effortScale),
                outOf = if (effortScale == EffortScale.WHOOP) 21.0 else 100.0,
                valueText = UnitFormatter.effortDisplay(liveStrain, effortScale),
                diameter = 150.dp,
                lineWidth = 14.dp,
            )
        }
    }
}

@Composable
private fun HeroHeartRate(bpm: Int?, zone: Int) {
    val tint = when {
        bpm == null -> Palette.textSecondary
        zone >= 1 -> Palette.hrZoneColor(zone)
        else -> Palette.effortColor
    }
    NoopCard(padding = 24.dp, tint = Palette.effortColor) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Overline("Heart rate")
            Box(contentAlignment = Alignment.Center) {
                // Soft zone-tinted halo behind the numeral — the Bevel glow.
                Box(
                    modifier = Modifier
                        .size(132.dp)
                        .clip(CircleShape)
                        .background(tint.copy(alpha = if (bpm == null) 0f else 0.14f)),
                )
                Text(bpm?.toString() ?: "—", style = NoopType.number(80f), color = tint)
            }
            Text("bpm", style = NoopType.subhead, color = Palette.textSecondary)
            Text(
                if (zone >= 1) "Zone $zone · ${zoneName(zone)}" else "Below Zone 1",
                style = NoopType.captionNumber,
                color = tint,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun ZoneRail(zone: Int, zoneSet: com.noop.analytics.HrZoneSet) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Overline("HR zone")
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
            (1..5).forEach { z ->
                val active = z == zone
                val color = Palette.hrZoneColor(z)
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(if (active) 44.dp else 34.dp)
                        .background(
                            if (active) color else color.copy(alpha = 0.18f),
                            RoundedCornerShape(8.dp),
                        )
                        .border(
                            1.dp,
                            if (active) color else Palette.hairline,
                            RoundedCornerShape(8.dp),
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "Z$z",
                        style = NoopType.captionNumber,
                        color = if (active) Palette.surfaceBase else Palette.textTertiary,
                    )
                }
            }
        }
        // The bpm band of the current zone, so the rail reads as concrete, not abstract.
        val band = zoneSet.zones.firstOrNull { it.number == zone }
        Text(
            if (band != null)
                "Zone $zone: ${band.lower.toInt()} - ${band.upper.toInt()} bpm (${(band.lowerPct * 100).toInt()} - ${(band.upperPct * 100).toInt()}% max HR)"
            else "Warming up - keep moving to climb into Zone 1.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

private fun zoneName(zone: Int): String = when (zone) {
    1 -> "Recovery"
    2 -> "Fat burn"
    3 -> "Aerobic"
    4 -> "Threshold"
    5 -> "Maximum"
    else -> ""
}
