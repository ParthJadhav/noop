import SwiftUI
import StrandDesign

// MARK: - WatchBreatheView — a wrist-native guided breathing session
//
// The phone is the brain for SCORES, but this runs entirely ON the watch: its own clock paces the breath,
// the Taptic engine carries the cue so it works with the wrist down and eyes closed, and a concentric guide
// ring swells on the inhale and settles on the exhale to match the iOS Breathe orb scaled to the wrist.
//
// The phase pattern + durations are reimplemented from Strand/Screens/BreathingView.swift (the fixed-pace
// "Breathe" trainer): three presets, inhale-then-exhale phases, one buzz on the inhale start and two on the
// exhale start. We do NOT link the iOS view (it depends on AppModel / LiveState / the strap haptic path that
// the watch doesn't have); this is a standalone WatchKit reimplementation that uses StrandHaptic for the
// wrist buzz instead of the strap motor.
//
// Self-contained, zero-arg init. The nav lane wires it in by name. Respects Reduce Motion (the ring parks at
// its mid radius and the phase word + haptic carry the pace instead of the swell).
struct WatchBreatheView: View {

    // MARK: Pace presets (mirrors the iOS BreathingView.Pace inhale/exhale seconds)

    private enum Pace: CaseIterable, Hashable {
        case relax       // 4s inhale / 6s exhale — long exhale, downshift to rest
        case coherence   // 5.5s / 5.5s — equal breath, ~5.5 br/min
        case box         // 4s / 4s — square breath, steady focus

        var label: String {
            switch self {
            case .relax:     return String(localized: "Relax")
            case .coherence: return String(localized: "Coherence")
            case .box:       return String(localized: "Box")
            }
        }

        /// Inhale seconds — same values the iOS fixed-pace trainer uses.
        var inhale: Double {
            switch self {
            case .relax:     return 4.0
            case .coherence: return 5.5
            case .box:       return 4.0
            }
        }

        /// Exhale seconds — same values the iOS fixed-pace trainer uses.
        var exhale: Double {
            switch self {
            case .relax:     return 6.0
            case .coherence: return 5.5
            case .box:       return 4.0
            }
        }

        var cycle: Double { inhale + exhale }
        var bpm: Double { 60.0 / cycle }
    }

    private enum Phase { case inhale, exhale }

    // MARK: State

    /// When Reduce Motion is on the swelling ring is suppressed — the breath is cued by the phase word +
    /// haptics instead, so the screen stays still. (watchOS a11y)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pace: Pace = .coherence
    @State private var running = false

    /// 0 = fully contracted, 1 = fully expanded. Drives the guide ring's radius, exactly like the iOS orb.
    @State private var ringProgress: CGFloat = 0
    @State private var phase: Phase = .inhale

    /// When the current phase ends (wall-clock). The 0.05s ticker compares against this so the pace stays
    /// true even if a frame is dropped, rather than counting ticks.
    @State private var phaseDeadline: Date = .distantFuture
    /// When the current phase began — used to drive the on-ring countdown.
    @State private var phaseStart: Date = Date()
    /// Seconds left in the current phase, recomputed each tick for the centre countdown.
    @State private var phaseRemaining: Int = 0

    @State private var breathCount = 0
    @State private var sessionSeconds = 0

    // A 0.05s clock advances the phases; a 1s clock counts the session length. Both gate on `running`.
    private let phaseTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let secondTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    /// Parked radius under Reduce Motion — the ring sits mid-way rather than pulsing.
    private let reducedSteadyRing: CGFloat = 0.5

    var body: some View {
        // One-screen fit: no ScrollView. A fixed compact header (the pace line) and a fixed control stack
        // (the 3 pace pills + Start/Stop) bracket the hero ring, and the ring is sized to whatever vertical
        // space is left over. That way every control stays on screen on any watch, from 41mm up, without
        // scrolling. The pace line + ring fold the session readout and the breath-cue caption into themselves
        // so we don't need the old footer row.
        GeometryReader { geo in
            let totalH = geo.size.height
            let totalW = geo.size.width
            let vSpacing: CGFloat = 6

            // Reserve room for the two fixed rows. These are deliberate floors that match the rendered
            // heights of paceLine, the pill row and the Start/Stop button so the ring can claim the rest.
            let headerH: CGFloat = 16          // the compact pace line
            let pillsH: CGFloat = 30           // the 3 pace pills
            let controlH: CGFloat = 38         // the Start/Stop button
            let reserved = headerH + pillsH + controlH + vSpacing * 3

            // Whatever's left is the ring's. Clamp so it never collapses or overflows the width.
            let remaining = max(totalH - reserved, 40)
            let ringSide = min(min(totalW, remaining), 150)

            VStack(spacing: vSpacing) {
                paceLine
                    .frame(height: headerH)
                ring(side: ringSide)
                Spacer(minLength: 0)
                pacePicker
                    .frame(height: pillsH)
                control
                    .frame(height: controlH)
            }
            .frame(width: totalW, height: totalH)
            .padding(.horizontal, 6)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onReceive(phaseTimer) { now in
            guard running else { return }
            advance(now: now)
            updateCountdown(now: now)
        }
        .onReceive(secondTimer) { _ in
            guard running else { return }
            sessionSeconds += 1
        }
        .onChange(of: pace) { _ in
            // Re-arm from the inhale at the new pace without an extra buzz (the user just tapped a pill).
            if running { armPhase(.inhale, from: Date(), buzz: false) }
        }
        .onDisappear { stop() }
    }

    // MARK: - The breathing ring

    /// A concentric guide ring on a near-black card: a faint resting track plus a brighter travelling ring
    /// that grows toward the track on the inhale and collapses on the exhale. The phase word + a per-phase
    /// countdown sit in the centre. Matches the iOS orb's behaviour, scaled to the wrist.
    private func ring(side: CGFloat) -> some View {
        let maxDiameter = side
        let minScale: CGFloat = 0.46
        let scale = minScale + (1.0 - minScale) * ringProgress
        let guideDiameter = maxDiameter * scale

        return ZStack {
            // The resting track the breath expands toward. Crisp 1px stroke, no glow.
            Circle()
                .strokeBorder(StrandPalette.restColor.opacity(0.26), lineWidth: 1)
                .frame(width: maxDiameter, height: maxDiameter)

            // A soft radial-shaded disc that swells with the breath (shading, not a bloom halo) — the
            // same cue as the iOS orb. Held steady under Reduce Motion.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [StrandPalette.restBright.opacity(0.85),
                                 StrandPalette.restColor.opacity(0.55),
                                 StrandPalette.restDeep.opacity(0.80)],
                        center: .init(x: 0.4, y: 0.35),
                        startRadius: 1,
                        endRadius: guideDiameter * 0.62
                    )
                )
                .frame(width: guideDiameter, height: guideDiameter)

            // The travelling guide ring — a brighter 2px stroke riding the breath out and back, the
            // crisp pace line on top of the soft swell.
            Circle()
                .strokeBorder(StrandPalette.restBright.opacity(running ? 0.70 : 0.40), lineWidth: 2)
                .frame(width: guideDiameter, height: guideDiameter)

            centerLabel
        }
        .frame(width: maxDiameter, height: maxDiameter)
        .frame(maxWidth: .infinity)
    }

    /// The phase word and, while running, the per-phase countdown. Idle it invites the user to begin.
    @ViewBuilder
    private var centerLabel: some View {
        VStack(spacing: 2) {
            if running {
                Text(phaseWord)
                    .font(StrandFont.rounded(15, weight: .semibold))
                    .foregroundStyle(StrandPalette.restBright)
                    .animation(.easeInOut(duration: 0.2), value: phase)
                Text("\(max(phaseRemaining, 0))")
                    .font(StrandFont.number(28))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                Text("Breathe")
                    .font(StrandFont.rounded(16, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(String(format: "%.1f", pace.bpm)) br/min")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        // Keep every centre word on ONE line — it sits inside the orb, which shrinks on the smallest
        // watch, so let the text scale down rather than wrap (no "Breath / e").
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(running ? phaseAccessibilityLabel : String(localized: "Ready to breathe"))
    }

    private var phaseWord: String {
        switch phase {
        case .inhale: return String(localized: "Breathe in")
        case .exhale: return String(localized: "Breathe out")
        }
    }

    /// Whole-phrase per phase (never a localized word stitched into a template) so each reads
    /// naturally in every language.
    private var phaseAccessibilityLabel: String {
        let secs = max(phaseRemaining, 0)
        switch phase {
        case .inhale: return String(localized: "Breathe in for \(secs) seconds")
        case .exhale: return String(localized: "Breathe out for \(secs) seconds")
        }
    }

    // MARK: - Pace line + picker

    private var paceLine: some View {
        // Compact one-liner. Running: the live session readout. Idle: the selected pace + a quick nod to the
        // wrist cue (folded in from the old footer so the "one tap in, two out" guidance still has a home).
        Text(running ? String(localized: "\(breathCount) breaths · \(timeString(sessionSeconds))")
                     : String(localized: "\(pace.label) · \(String(format: "%.0f", pace.inhale))s in / \(String(format: "%.0f", pace.exhale))s out"))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }

    /// Three preset pills. Disabled mid-session would feel abrupt; instead picking a new pace re-arms the
    /// breath cleanly (handled in onChange), so the user can switch on the fly.
    private var pacePicker: some View {
        HStack(spacing: 6) {
            ForEach(Pace.allCases, id: \.self) { p in
                Button {
                    StrandHaptic.selection.play()
                    pace = p
                } label: {
                    Text(p.label)
                        .font(StrandFont.caption)
                        .foregroundStyle(p == pace ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(p == pace ? StrandPalette.restColor.opacity(0.22) : StrandPalette.surfaceRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(p == pace ? StrandPalette.restBright.opacity(0.6) : Color.clear,
                                              lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(p.label) pace")
                .accessibilityAddTraits(p == pace ? [.isSelected] : [])
            }
        }
    }

    // MARK: - Start / stop

    private var control: some View {
        Button {
            running ? stop() : start()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(running ? String(localized: "Stop") : String(localized: "Start"))
                    .font(StrandFont.rounded(15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(running ? StrandPalette.statusCritical.opacity(0.22)
                                  : StrandPalette.restColor.opacity(0.28))
            )
            .foregroundStyle(running ? StrandPalette.statusCritical : StrandPalette.restBright)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(running ? String(localized: "Stop session") : String(localized: "Start session"))
    }

    // MARK: - Session control

    private func start() {
        running = true
        sessionSeconds = 0
        breathCount = 0
        StrandHaptic.success.play()
        armPhase(.inhale, from: Date(), buzz: true)
    }

    private func stop() {
        guard running else { return }
        running = false
        phaseDeadline = .distantFuture
        StrandHaptic.commit.play()
        if reduceMotion {
            ringProgress = 0
        } else {
            withAnimation(.easeInOut(duration: 0.7)) { ringProgress = 0 }
        }
    }

    /// Arm a new phase: set its deadline, animate the ring toward the target radius over the phase duration,
    /// and (when `buzz`) fire the wrist haptic — one tap on the inhale start, two on the exhale start, so the
    /// pace is felt without looking. Mirrors the iOS armPhase, swapping the strap buzz for StrandHaptic.
    private func armPhase(_ newPhase: Phase, from now: Date, buzz: Bool) {
        phase = newPhase
        let duration = (newPhase == .inhale) ? pace.inhale : pace.exhale
        phaseStart = now
        phaseDeadline = now.addingTimeInterval(duration)
        phaseRemaining = Int(duration.rounded(.up))

        if reduceMotion {
            ringProgress = reducedSteadyRing
        } else {
            withAnimation(.easeInOut(duration: duration)) {
                ringProgress = (newPhase == .inhale) ? 1.0 : 0.0
            }
        }

        if buzz {
            // One tap leading the inhale, a double tap leading the exhale — the iOS 1-buzz / 2-buzz cue,
            // reproduced on the wrist. The second exhale tap is nudged slightly so they read as a pair.
            StrandHaptic.light.play()
            if newPhase == .exhale {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    StrandHaptic.light.play()
                }
            }
        }
    }

    private func advance(now: Date) {
        guard now >= phaseDeadline else { return }
        switch phase {
        case .inhale:
            armPhase(.exhale, from: now, buzz: true)
        case .exhale:
            breathCount += 1
            armPhase(.inhale, from: now, buzz: true)
        }
    }

    /// Recompute the centre countdown from the wall clock so it ticks down 1-by-1 in step with the phase.
    private func updateCountdown(now: Date) {
        let left = phaseDeadline.timeIntervalSince(now)
        phaseRemaining = max(0, Int(left.rounded(.up)))
    }

    // MARK: - Formatting

    private func timeString(_ total: Int) -> String {
        String(format: "%d:%02d", total / 60, total % 60)
    }
}
