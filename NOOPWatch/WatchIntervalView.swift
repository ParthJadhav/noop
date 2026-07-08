import SwiftUI
import StrandDesign

// MARK: - WatchIntervalView — silent haptic HIIT, on the wrist
//
// The watch-native sibling of the phone's Interval Timer (Strand/Screens/IntervalTimerView.swift). Same
// model: a WORK / REST state machine over a number of rounds with the session total derived from
// work*rounds + rest*(rounds-1). The difference is where the buzz lands. On the phone the strap (or the
// phone's own Taptic engine) cues the transitions; here the watch IS on your wrist, so we fire WatchKit
// haptics through StrandHaptic at every WORK<->REST flip and round change. Train hands-free and let the
// wrist tell you when to switch, never looking at the face.
//
// Defaults match the phone: 30s work / 15s rest / 8 rounds. Scaled for the watch: one big countdown ring
// is the whole screen (flat track + solid phase-tinted arc, SF-Rounded number in the centre, WHOOP-grey
// card), with the WORK/REST chip and ROUND x/N above it and compact Start/Pause + Reset below. No config
// steppers up here on the small face — the wrist is for running the session, the phone owns setup.
struct WatchIntervalView: View {

    // Cross-lane contract: a no-arg init, fully self-contained.
    init() {}

    // MARK: Config (the phone's defaults — fixed on the watch, run-only surface)

    private let workSeconds = 30
    private let restSeconds = 15
    private let rounds = 8

    // MARK: Run state

    private enum Phase {
        case work, rest, done
        var label: String {
            switch self {
            case .work: return String(localized: "WORK")
            case .rest: return String(localized: "REST")
            case .done: return String(localized: "DONE")
            }
        }
    }

    @State private var phase: Phase = .work
    @State private var currentRound = 1
    @State private var remaining = 30      // seconds left in the current phase
    @State private var running = false
    @State private var elapsed = 0         // total elapsed seconds across the session

    // 1Hz tick, same cadence as the phone.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: Derived

    private var phaseDuration: Int {
        switch phase {
        case .work: return max(1, workSeconds)
        case .rest: return max(1, restSeconds)
        case .done: return 1
        }
    }

    /// 0...1 progress through the current interval.
    private var intervalProgress: Double {
        guard phaseDuration > 0 else { return 0 }
        let done = Double(phaseDuration - remaining)
        return min(1, max(0, done / Double(phaseDuration)))
    }

    /// The active phase's reset token: WORK uses the Effort blue, REST the Rest blue-grey, DONE the
    /// positive green. Tints the flat ring arc + the phase chip only (no glow), matching the phone.
    private var phaseColor: Color {
        switch phase {
        case .work: return StrandPalette.effortColor
        case .rest: return StrandPalette.restColor
        case .done: return StrandPalette.statusPositive
        }
    }

    private var isFinished: Bool { phase == .done }

    // MARK: Body

    var body: some View {
        // One-screen fit: no ScrollView. A fixed compact header + a fixed control row top-and-tail the
        // face, and the countdown ring takes exactly the space left between them. Sizing the hero to the
        // remaining height means Start/Pause + Reset are always on screen, on a 41mm right up to an Ultra,
        // with nothing ever falling below the fold.
        GeometryReader { geo in
            let spacing: CGFloat = 6
            // Measured constants for the two fixed rows so we can hand the ring whatever's left over.
            let headerHeight: CGFloat = 26
            let controlsHeight: CGFloat = 34
            let available = geo.size.height
                - headerHeight - controlsHeight
                - spacing * 2          // the two gaps between the three rows
            // Clamp the ring to the smaller of the width and the leftover height, with a sane floor so it
            // never collapses to nothing on the tightest faces.
            let ringSpace = min(geo.size.width, max(available, 64))
            let diameter = max(64, min(ringSpace, 150))

            VStack(spacing: spacing) {
                header
                    .frame(height: headerHeight)
                heroRing(diameter: diameter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .frame(height: controlsHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 4)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onReceive(ticker) { _ in tick() }
        .onAppear { if remaining == 0 { resetToStart() } }
    }

    // MARK: Header — phase chip + round chip

    private var header: some View {
        HStack {
            phaseChip
            Spacer(minLength: 6)
            roundChip
        }
        .frame(maxWidth: .infinity)
    }

    /// Tinted phase pill (WORK / REST / DONE).
    private var phaseChip: some View {
        Text(phase.label)
            .font(StrandFont.rounded(13, weight: .heavy))
            .tracking(1.5)
            .foregroundStyle(phaseColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(phaseColor.opacity(0.16), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(phaseColor.opacity(0.35), lineWidth: 1))
    }

    /// "ROUND n / N" chip.
    private var roundChip: some View {
        HStack(spacing: 3) {
            Text("\(min(currentRound, rounds))")
                .font(StrandFont.number(15))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("/ \(rounds)")
                .font(StrandFont.number(15))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
        .accessibilityLabel("Round \(min(currentRound, rounds)) of \(rounds)")
    }

    // MARK: Hero ring — the countdown

    /// Flat phase-progress ring (visible track + solid reset-token arc, no glow) with the countdown number
    /// + caption centred, scaled down to the wrist. Same look as the phone's heroRing, just smaller. The
    /// diameter comes from the body's GeometryReader so the ring soaks up whatever vertical space is left
    /// after the fixed header + controls, keeping every control on one screen.
    private func heroRing(diameter: CGFloat) -> some View {
        // Stroke scales with the ring so it stays proportional from a 41mm right up to an Ultra.
        let lineWidth: CGFloat = max(7, min(11, diameter * 0.085))
        let fraction = isFinished ? 1 : intervalProgress
        return ZStack {
            // Visible full-circle track so the arc reads as a fraction of a circle (WHOOP-style).
            Circle()
                .stroke(StrandPalette.textPrimary.opacity(0.10),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            // Flat, crisp solid arc — no glow.
            Circle()
                .trim(from: 0, to: max(0.0001, CGFloat(min(max(fraction, 0), 1))))
                .rotation(.degrees(-90))
                .stroke(phaseColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .animation(.snappy, value: fraction)
            // Centred countdown number + caption.
            VStack(spacing: 2) {
                Text(isFinished ? "✓" : "\(remaining)")
                    .font(GlowRing.centerFont(diameter: diameter))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                Text(isFinished ? String(localized: "DONE") : String(localized: "SEC"))
                    .font(StrandFont.overlineScaled(9))
                    .tracking(1.5)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, lineWidth + 3)
        }
        .frame(width: diameter, height: diameter)
        .animation(.snappy, value: remaining)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFinished ? String(localized: "Session done")
                                        : String(localized: "\(remaining) seconds remaining in \(phase.label)"))
    }

    // MARK: Controls — Start/Pause + Reset

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                if isFinished { resetToStart() }
                toggleRunning()
            } label: {
                Label(running ? String(localized: "Pause")
                              : (isFinished ? String(localized: "Restart") : String(localized: "Start")),
                      systemImage: running ? "pause.fill" : "play.fill")
                    .font(StrandFont.rounded(14, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .tint(phaseColor)

            Button {
                stopAndReset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .tint(StrandPalette.surfaceRaised)
            .accessibilityLabel("Reset")
            .disabled(isCleanStart)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    /// True when nothing has run yet — disables Reset so it never looks active on a fresh session.
    private var isCleanStart: Bool {
        !running && phase == .work && currentRound == 1
            && remaining == max(1, workSeconds) && elapsed == 0
    }

    // MARK: Timer logic (reimplemented to match the phone's parameters)

    private func tick() {
        guard running, !isFinished else { return }

        // 3-2-1 countdown tick on the last seconds of the current phase — a light wrist tap.
        if remaining <= 3 && remaining >= 1 {
            StrandHaptic.selection.play()
        }

        if remaining > 1 {
            remaining -= 1
            elapsed += 1
            return
        }

        // remaining hits 0 — advance to the next phase/round.
        elapsed += 1
        advancePhase()
    }

    private func advancePhase() {
        switch phase {
        case .work:
            if currentRound >= rounds {
                // Last work block finished → session complete.
                finishSession()
            } else {
                // Into rest — a soft single cue.
                phase = .rest
                remaining = max(1, restSeconds)
                StrandHaptic.light.play()
            }
        case .rest:
            // Rest done → next round's work — a strong cue so you feel it without looking.
            currentRound += 1
            phase = .work
            remaining = max(1, workSeconds)
            StrandHaptic.commit.play()
        case .done:
            break
        }
    }

    private func finishSession() {
        withAnimation(.snappy) {
            phase = .done
            remaining = 0
            running = false
        }
        StrandHaptic.success.play()         // long completion cue
    }

    private func toggleRunning() {
        if isFinished { return }
        if running {
            running = false
        } else {
            // Starting fresh from a clean reset → fire the opening WORK cue, like the phone does.
            let startingFresh = isCleanStart
            running = true
            if startingFresh { StrandHaptic.commit.play() }
        }
    }

    private func stopAndReset() {
        running = false
        resetToStart()
    }

    /// Reset run state back to round 1 / start of work, using current config.
    private func resetToStart() {
        phase = .work
        currentRound = 1
        remaining = max(1, workSeconds)
        elapsed = 0
    }
}

#if DEBUG
#Preview("Watch Interval") {
    WatchIntervalView()
}
#endif
