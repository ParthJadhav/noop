import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Live workout mode (#238) — the in-exercise screen: a big live heart rate, the current HR zone,
/// elapsed time, and live effort building, all from the SAME live feed and scorers the rest of the
/// app uses (no invented numbers). Presented while a manual workout is active, entered from the
/// Start-workout control on Live. End stops the workout and dismisses.
///
/// Live HR is the smoothed `AppModel.bpm`; the zone is derived from the user's HR-max via the shared
/// `HRZones` model; elapsed time ticks from the workout's start (a TimelineView, no manual Timer);
/// effort is the running `ActiveWorkout.liveStrain` (StrainScorer over the captured window).
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    // PERF (scroll/recompose): this screen deliberately does NOT observe `LiveState` directly. A connected
    // strap publishes `LiveState` ~1 Hz (HR + each R-R packet, plus sensor frames), and an
    // `@EnvironmentObject live` here would invalidate the WHOLE body on every tick — the HR hero, effort
    // gauge, zone rail and stats grid all re-evaluate even though they read from `model` (smoothed bpm +
    // scorers), not `live`. The only region that genuinely needs `live` is the additive sensor readout
    // (speed / cadence / power), so it's extracted into the small `SensorRowIfPresent` leaf below that
    // owns its OWN `@EnvironmentObject live`. A sensor/R-R packet now re-renders just that row, not the
    // hero. (`model.live` is its own ObservableObject, so the leaf's `live` is the one that sees the
    // @Published changes — exactly as the parent's direct observation did before.)
    let onClose: () -> Void

    /// Effort display scale (#268) — routes the live Effort read-out through the shared helper so it
    /// matches every other surface. Display-only; the captured value stays stored 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Keep the screen awake while recording (#703). Opt-in, default off; the toggle lives in Settings.
    /// Read here so we can hold the idle timer off only while this in-exercise screen is up and release it
    /// the moment it leaves, which is exactly the bounded usage Apple asks for. iOS-only (no-op on Mac).
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    private var zoneSet: HRZoneSet { HRZones.zones(maxHR: Double(model.profile.hrMax)) }
    private var zone: Int { model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                let cards: [AnyView] = [
                    AnyView(header),
                    AnyView(heroHeartRate),
                    AnyView(effortGauge),
                    AnyView(zoneRail),
                    AnyView(statsGrid),
                ]
                ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                    card.staggeredAppear(index: index)
                }
                // Live-observing leaf: renders the sensor row (and its entrance stagger) only when a
                // standard fitness sensor is feeding metrics, refreshing on its own packets without
                // re-rendering the HR hero / effort gauge above (scroll-stutter isolation).
                SensorRowIfPresent()
                Spacer(minLength: NoopMetrics.space3)
                endButton
            }
            .screenPadding()
            .padding(.vertical, NoopMetrics.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A scenic Effort-tinted backdrop behind the whole in-exercise screen, fading to the base — the
        // live workout reads as an Effort-world hero, not a flat panel.
        .background {
            ScenicHeroBackground(domain: .effort)
                .ignoresSafeArea()
        }
        // If the workout ended elsewhere (process restart cleared it), close the screen.
        .onChangeCompat(of: model.activeWorkout == nil) { gone in if gone { onClose() } }
        // Arm the realtime HR stream while the in-exercise screen is up (#681). On a WHOOP 5/MG live HR
        // only flows while the puffin realtime stream is armed; previously only the Live tab armed it, so
        // starting a manual workout straight from Workouts (Live never opened) left `model.bpm == nil` —
        // captureWorkoutSample bailed on every sample and endWorkout silently discarded the empty
        // session. Ref-counted in AppModel, so when this sheet sits over an already-armed Live tab the
        // two balance and neither disarms the other (mirrors Android LiveWorkoutScreen's DisposableEffect
        // requestRealtimeHr/releaseRealtimeHr). Balanced: one start on appear, one stop on disappear.
        .onAppear {
            model.startRealtimeHR()
            // Hold the display awake for the session only if the user opted in (#703).
            if keepScreenOn { ScreenIdle.keepAwake(true) }
        }
        .onDisappear {
            model.stopRealtimeHR()
            // Always release on the way out so the system idle timer resumes. Even if the toggle was
            // flipped off mid-workout, this clears any hold we placed.
            ScreenIdle.keepAwake(false)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RECORDING WORKOUT")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.metricRose)
                Text("Workout")
                    .font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            if let start = model.activeWorkout?.start {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.elapsed(since: start))
                        .font(StrandFont.number(34)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
        }
    }

    private var heroHeartRate: some View {
        let tint = zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
        return NoopCard(padding: NoopMetrics.space6, tint: StrandPalette.effortColor) {
            VStack(spacing: NoopMetrics.space2) {
                Text("HEART RATE")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                // The big live HR ticks up to its new reading on each beat — crisp, flat, no halo.
                if let bpm = model.bpm {
                    CountUpText(value: Double(bpm),
                                format: { "\(Int($0.rounded()))" },
                                font: StrandFont.rounded(80, weight: .semibold),
                                color: tint)
                } else {
                    Text("—")
                        .font(StrandFont.rounded(80, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text("bpm").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Text(zone >= 1 ? "Zone \(zone) · \(Self.zoneName(zone))" : "Below Zone 1")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The accumulating Effort, on the same layered StrainGauge the rest of the app uses — the live
    /// `liveStrain` is on NOOP's 0–100 Effort axis. The gauge renders on the user's selected Effort
    /// scale (#313): 0–100 native, or rescaled to WHOOP's 0–21, matching the rest of the app's
    /// read-outs (mirrors TodayView's effort hero). Display-only — the captured value stays 0–100.
    private var effortGauge: some View {
        let strain = model.activeWorkout?.liveStrain ?? 0
        return NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.effortColor) {
            VStack(spacing: NoopMetrics.rowSpacing) {
                Text("EFFORT BUILDING")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.effortColor)
                StrainGauge(
                    strain: UnitFormatter.effortValue(strain, scale: effortScale),
                    outOf: effortScale == .whoop ? 21 : 100,
                    diameter: 150, lineWidth: 14, showsHover: false,
                    valueFormat: { _ in UnitFormatter.effortDisplay(strain, scale: effortScale) }
                )
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var zoneRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HR ZONE")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { z in
                    let active = z == zone
                    let color = StrandPalette.hrZoneColor(z)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? color : color.opacity(0.18))
                        .frame(height: active ? 44 : 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(active ? color : StrandPalette.hairline, lineWidth: 1)
                        )
                        .overlay(
                            Text("Z\(z)")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(active ? StrandPalette.surfaceBase : StrandPalette.textTertiary)
                        )
                }
            }
            if let band = zoneSet.zones.first(where: { $0.number == zone }) {
                Text("Zone \(zone): \(Int(band.lower))-\(Int(band.upper)) bpm (\(Int(band.lowerPct * 100))-\(Int(band.upperPct * 100))% max HR)")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text("Warming up. Keep moving to climb into Zone 1.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var statsGrid: some View {
        let w = model.activeWorkout
        return HStack(spacing: NoopMetrics.gap) {
            stat(String(localized: "AVG"), (w?.avgHr ?? 0) > 0 ? "\(w!.avgHr)" : "—",
                 tint: (w?.avgHr ?? 0) > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
            stat(String(localized: "PEAK"), (w?.peakHr ?? 0) > 0 ? "\(w!.peakHr)" : "—",
                 tint: (w?.peakHr ?? 0) > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
            stat(String(localized: "EFFORT"), UnitFormatter.effortDisplay(w?.liveStrain ?? 0, scale: effortScale),
                 tint: StrandPalette.strainColor(w?.liveStrain ?? 0))
        }
    }

    private func stat(_ title: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        NoopCard(padding: 14, tint: tint) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(value)
                    .font(StrandFont.number(26))
                    .foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var endButton: some View {
        NoopButton("End workout", systemImage: "stop.fill", kind: .destructive, fullWidth: true) {
            model.endWorkout()
            onClose()
        }
    }

    // MARK: - Helpers

    private static func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func zoneName(_ zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Recovery")
        case 2: return String(localized: "Fat burn")
        case 3: return String(localized: "Aerobic")
        case 4: return String(localized: "Threshold")
        case 5: return String(localized: "Maximum")
        default: return ""
        }
    }
}

// MARK: - Live-observing leaf (scroll-stutter isolation)

/// Additive readout for a connected standard fitness sensor (a footpod / bike speed-cadence sensor /
/// power meter) feeding RSC/CSC/CPS ALONGSIDE heart rate. Only the fields the sensor actually sent
/// render — each tile is dropped when its value is absent, and the WHOLE block (row + entrance stagger)
/// is hidden when nothing is present (`live.hasSensorMetrics`), so a plain HR-only workout looks exactly
/// as before. Honest units: speed km/h, cadence per-minute (steps for running / rpm for cycling), power
/// watts. Tinted with the Effort world so it reads as part of the hero, not a competing accent. Nothing
/// here touches HR / zone / effort.
///
/// This is a standalone leaf that owns its OWN `@EnvironmentObject live` (the parent `LiveWorkoutView`
/// no longer observes `LiveState`), so an incoming sensor / R-R packet re-renders only this row, not the
/// HR hero / effort gauge / zone rail above. The gate, layout and `staggeredAppear(index: 5)` are
/// preserved verbatim, so the rendered output is byte-for-byte the previous inline code.
private struct SensorRowIfPresent: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        if live.hasSensorMetrics {
            let speed = LiveState.formatSpeedKmh(live.sensorSpeedKmh)
            let cadence = LiveState.formatCadence(live.sensorCadence)
            let power = LiveState.formatPowerWatts(live.sensorPowerWatts)
            VStack(alignment: .leading, spacing: 8) {
                Text("SENSOR")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: NoopMetrics.gap) {
                    if let speed { stat(String(localized: "SPEED"), "\(speed) km/h", tint: StrandPalette.effortColor) }
                    if let cadence { stat(String(localized: "CADENCE"), "\(cadence)/min", tint: StrandPalette.effortColor) }
                    if let power { stat(String(localized: "POWER"), "\(power) W", tint: StrandPalette.effortColor) }
                }
            }
            .staggeredAppear(index: 5)
        }
    }

    /// Same metric tile as `LiveWorkoutView.stat` (the HR stats grid) — duplicated here, unchanged, so the
    /// leaf is self-contained and the rendered tile is identical.
    private func stat(_ title: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        NoopCard(padding: 14, tint: tint) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(value)
                    .font(StrandFont.number(26))
                    .foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
