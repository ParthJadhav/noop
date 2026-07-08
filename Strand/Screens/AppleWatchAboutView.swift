import SwiftUI
import StrandDesign

// MARK: - About Apple Watch data
//
// The honest "what your Apple Watch is good at, and where it's lighter" page (M2 of the
// Watch-as-a-device project). NOOP can run off only an Apple Watch (the phone computes our
// Charge / Rest / Effort / Fitness Age live from HealthKit) but the watch is not a chest
// strap, and this page says so plainly. It renders the per-metric capability + confidence
// table from the design spec, the HRV-sampling explanation (why recovery calibrates over
// about a week), and the SpO2 caveat (the newest US units dropped the sensor).
//
// This is content only: it reads from no store and holds no live state, so it renders the
// SAME on macOS and iOS. The actual permission request lives in the setup flow
// (AppleWatchSetupView), which this page links to. Reachable from Settings → About.
//
// Honest tone, plain voice, no fabricated numbers. Every confidence label here is the same
// honest "Great / Good / Calibrating / Not available" stance the scores use on Today.

/// One row of the capability/confidence table: a metric, where the watch sits on it, and a
/// plain line of why. The confidence drives the row's accent + pill, so a glance reads honestly.
private struct WatchMetric: Identifiable {
    enum Confidence {
        case great        // use it as-is, the watch is strong here
        case good         // solid, with a small caveat
        case calibrating  // needs a baseline first, no fabricated number until then
        case unavailable  // the sensor or model can't honestly support it

        var pillLabel: String {
            switch self {
            case .great:        return String(localized: "Great")
            case .good:         return String(localized: "Good")
            case .calibrating:  return String(localized: "Calibrating")
            case .unavailable:  return String(localized: "Not available")
            }
        }

        var tone: StrandTone {
            switch self {
            case .great:        return .positive
            case .good:         return .accent
            case .calibrating:  return .warning
            case .unavailable:  return .neutral
            }
        }

        var accent: Color {
            switch self {
            case .great:        return StrandPalette.statusPositive
            case .good:         return StrandPalette.accent
            case .calibrating:  return StrandPalette.statusWarning
            case .unavailable:  return StrandPalette.textTertiary
            }
        }
    }

    let id = UUID()
    let icon: String
    let metric: String
    let confidence: Confidence
    let detail: String
}

struct AppleWatchAboutView: View {
    /// Optional hook so the page can present the setup/permission flow. The About page links to
    /// it as its primary call to action; left nil (e.g. on macOS, which has no HealthKit) the
    /// button is hidden and the page reads as pure reference content.
    var onStartSetup: (() -> Void)?

    init(onStartSetup: (() -> Void)? = nil) {
        self.onStartSetup = onStartSetup
    }

    // The honest table, straight from the spec's scoring + confidence map. Order runs from what
    // the watch is strongest at down to what it can't honestly do, so the page reads as a fair
    // appraisal rather than a sales pitch.
    private let metrics: [WatchMetric] = [
        WatchMetric(icon: "bed.double.fill", metric: String(localized: "Sleep / Rest"),
                    confidence: .great,
                    detail: String(localized: "Apple's own sleep stages drive Rest directly. This is one of the watch's strengths.")),
        WatchMetric(icon: "figure.walk", metric: String(localized: "Steps & workouts"),
                    confidence: .great,
                    detail: String(localized: "Steps, active energy and logged workouts feed Effort. Dense and reliable.")),
        WatchMetric(icon: "lungs.fill", metric: String(localized: "Fitness Age"),
                    confidence: .great,
                    detail: String(localized: "Built from Apple's cardio-fitness VO₂ max estimate, the same number the Fitness app shows.")),
        WatchMetric(icon: "flame.fill", metric: String(localized: "Effort"),
                    confidence: .good,
                    detail: String(localized: "Heart rate plus active energy give a solid daily cardiovascular load. An on-watch workout sharpens it further.")),
        WatchMetric(icon: "heart.fill", metric: String(localized: "Recovery / Charge"),
                    confidence: .calibrating,
                    detail: String(localized: "Led by your heart-rate variability versus your own baseline. The watch samples HRV rather than streaming it, so this needs about a week of nights to calibrate. Until then NOOP shows \u{201C}needs more data\u{201D}, never a guessed number.")),
        WatchMetric(icon: "thermometer.medium", metric: String(localized: "Skin temperature"),
                    confidence: .good,
                    detail: String(localized: "From the watch's wrist-temperature sensor during sleep, on Series 8 and later. Older models don't have the sensor, so it reads \u{201C}not available\u{201D} rather than zero.")),
        WatchMetric(icon: "drop.degreesign", metric: String(localized: "Blood oxygen (SpO₂)"),
                    confidence: .unavailable,
                    detail: String(localized: "Trend only where supported, and Apple removed the SpO₂ sensor from the newest US units, so on those it simply isn't there. NOOP shows nothing rather than a fake reading.")),
    ]

    var body: some View {
        ScreenScaffold(title: "About Apple Watch data",
                       subtitle: "What your watch is great at, where it's lighter than a chest strap, and how sure NOOP is.",
                       lazy: true) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                introCard
                capabilityCard
                hrvCard
                spo2Card
                if let onStartSetup {
                    startCard(onStartSetup)
                }
                footerNote
            }
        }
    }

    // MARK: - Intro

    private var introCard: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "applewatch")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 34, height: 34)
                        .background(StrandPalette.accent.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Your Apple Watch as a device")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 0)
                }
                Text("NOOP can run off only an Apple Watch, no chest strap needed. The watch is the sensor; NOOP does the thinking on your phone, computing Charge, Rest, Effort and your Fitness Age from your Health data, all on-device.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The honest catch: a watch isn't a chest strap. It's brilliant at sleep, steps, workouts and fitness, and lighter on the dense heart-rate-variability a strap measures all night. So recovery takes about a week to calibrate, and a couple of metrics depend on your watch model. NOOP is upfront about all of it. Every watch-derived number carries a confidence, and where the watch can't be honest, NOOP shows nothing instead of a made-up figure.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Capability + confidence table

    private var capabilityCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("WHAT THE WATCH CAN DO").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Each metric, where your Apple Watch sits on it, and why.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(metrics.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().overlay(StrandPalette.hairline)
                                .padding(.vertical, 12)
                        }
                        metricRow(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metricRow(_ item: WatchMetric) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.confidence.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(item.metric)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                StatePill(LocalizedStringKey(item.confidence.pillLabel),
                          tone: item.confidence.tone, showsDot: true)
            }
            Text(item.detail)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // One accessible element per metric: the screen reader hears the metric, its confidence,
        // and the plain explanation as a single, honest unit instead of three loose fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.metric). \(item.confidence.pillLabel). \(item.detail)")
    }

    // MARK: - HRV-sampling explanation

    private var hrvCard: some View {
        NoopCard(tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.chargeColor)
                        .accessibilityHidden(true)
                    Text("Why recovery calibrates over about a week")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Recovery, NOOP's Charge score, is led by your heart-rate variability measured against your own personal baseline. A chest strap streams beat-to-beat data densely all night, so it can learn that baseline fast. An Apple Watch instead samples HRV, a handful of readings through the day plus overnight, so the signal is real but sparser.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("That's why a watch-only Charge starts out \u{201C}Calibrating\u{201D}. NOOP needs about seven nights of your HRV to learn what normal looks like for you. Until it has them it withholds the score rather than guess. Once the baseline is set, your Charge appears with its confidence, on the same 0-100 scale as a strap's.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - SpO2 caveat

    private var spo2Card: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "drop.degreesign")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.metricCyan)
                        .accessibilityHidden(true)
                    Text("A note on blood oxygen and your model")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("A couple of metrics depend on which Apple Watch you wear. Wrist temperature, which feeds skin temp, arrived with Series 8, so older watches don't report it. Blood oxygen is the bigger one: Apple removed the SpO₂ sensor from the newest US units over a patent dispute, so those simply don't measure it.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Where a sensor isn't on your watch, NOOP reads \u{201C}not available\u{201D} for that metric, never a zero, never an invented number. Everything else keeps working.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start setup (iOS only; injected by the caller)

    private func startCard(_ start: @escaping () -> Void) -> some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ready to connect your watch?")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("NOOP reads your Apple Watch data through Apple Health, on your phone, nothing leaves the device. You choose exactly what to share.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: start) {
                    Label("Set up Apple Watch", systemImage: "applewatch")
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .accessibilityHint("Opens the Apple Watch setup and Health permission")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerNote: some View {
        Text("These are independent estimates computed on your device from your Apple Health data, not medical advice. Confidence labels are honest about how much NOOP knows so far.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

#if DEBUG
#Preview("About Apple Watch data") {
    NavigationStack {
        AppleWatchAboutView(onStartSetup: {})
    }
    .preferredColorScheme(.dark)
}
#endif
