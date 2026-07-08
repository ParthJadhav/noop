import SwiftUI
import StrandDesign

// MARK: - WatchGlanceView — the watch app's single primary screen
//
// The Apple-Fitness-x-WHOOP look scaled to the wrist: the three NOOP rings (Charge / Effort / Rest) with
// their numbers in SF-Rounded, each honouring confidence (a calibrating score shows a dash plus a small
// "cal" marker, NEVER a fabricated number), a live heart-rate readout from the watch's own sensor, and a
// one-line sleep summary. When nothing has synced yet we show a friendly "open NOOP on your iPhone" state,
// and we always label the scores with the snapshot's age ("as of 2h ago") rather than implying they are live.
struct WatchGlanceView: View {
    @EnvironmentObject private var store: WatchScoreStore
    @EnvironmentObject private var liveHR: WatchLiveHR

    var body: some View {
        // The glance is page 1 of the watch app's swipeable page deck (WatchRootView): just the synced
        // scores, sized to ONE screen with no scrolling. Breathe / Workout / Intervals are their OWN pages
        // a swipe away, so the glance no longer pushes or links anywhere. The phone is the brain for the
        // SCORES here; the active features run on the watch's own sensors + haptics on their pages.
        Group {
            if let snap = store.snapshot {
                glance(snap)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onAppear { liveHR.start() }
        .onDisappear { liveHR.stop() }
    }

    // MARK: Synced state

    @ViewBuilder
    private func glance(_ snap: WatchScoreSnapshot) -> some View {
        // One staleness decision for the whole glance: when the snapshot has aged out (per the shared
        // contract) we force every ring into its empty-track + dash branch so an arbitrarily old
        // snapshot never shows live-looking numbers. The honest recency line below says how old it is.
        let stale = snap.isStale()
        VStack(spacing: 12) {
            // The three score rings. Each renders a number only when the phone earned one AND it is
            // still current; a calibrating OR stale score is a dash with a small "cal" marker so we
            // never show a value we did not compute or one that is no longer current.
            HStack(spacing: 8) {
                // The labels ride a plain String property into ScoreRing, so they must be wrapped HERE;
                // a bare literal would bypass the string catalog entirely.
                ScoreRing(label: String(localized: "Charge"), value: snap.charge,
                          calibrating: snap.chargeCalibrating || stale,
                          color: StrandPalette.chargeColor)
                ScoreRing(label: String(localized: "Effort"), value: snap.effort,
                          calibrating: snap.effortCalibrating || stale,
                          color: StrandPalette.effortColor)
                ScoreRing(label: String(localized: "Rest"), value: snap.rest,
                          calibrating: snap.restCalibrating || stale,
                          color: StrandPalette.restColor)
            }
            .frame(maxWidth: .infinity)

            heartRate
            // A stale snapshot's sleep line is also out of date, so drop it rather than imply it is today's.
            if !stale { sleepLine(snap.sleepSummary) }
            asOf(snap)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    /// Live heart rate from the watch's own sensor. Honest about denial: "HR unavailable" when HealthKit
    /// access was refused, a dash until the first sample lands, then the live BPM.
    private var heartRate: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 13))
                .foregroundStyle(StrandPalette.statusCritical)
            if liveHR.denied {
                Text("HR unavailable")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text(liveHR.bpm.map(String.init) ?? "–")
                    .font(StrandFont.rounded(20, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                Text("bpm")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
    }

    /// One-line sleep summary straight from the phone (e.g. "7h 12m · 81% Rest"). Empty string = skip it.
    @ViewBuilder
    private func sleepLine(_ summary: String) -> some View {
        if !summary.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.restColor)
                Text(summary)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The honesty line: how recent the synced scores are, straight from the shared contract so the
    /// glance and the complication phrase it identically ("Today" / "Yesterday" / "2h ago"). When the
    /// snapshot is stale the rings above are already dashes, and this line carries the recency.
    private func asOf(_ snap: WatchScoreSnapshot) -> some View {
        let fresh = snap.freshnessText()
        return Text(snap.isStale() ? String(localized: "stale · \(fresh)") : String(localized: "as of \(fresh)"))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 28))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Open NOOP on your iPhone to sync")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(.horizontal, 12)
    }

    // Snapshot recency now comes from the shared contract (`freshnessText` / `isStale` on
    // WatchScoreSnapshot) so the glance and the complication never drift apart. The old local
    // ageString helper was retired with that move.
}

// MARK: - ScoreRing — one clean NOOP ring scaled for the wrist
//
// Wraps the shared GlowRing (the flat, crisp Apple-Fitness-x-WHOOP arc) so the watch matches the phone's
// rings exactly. A calibrating score draws an EMPTY track with a dash centre and a small "cal" marker
// underneath, never a fabricated fill or number. Reduce-motion is respected inside GlowRing itself.
private struct ScoreRing: View {
    let label: String
    let value: Double?
    let calibrating: Bool
    let color: Color

    private let diameter: CGFloat = 52
    private let lineWidth: CGFloat = 6

    var body: some View {
        VStack(spacing: 4) {
            ring
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var ring: some View {
        if let value, !calibrating {
            // A real, earned score: the clean filled arc with its SF-Rounded number in the centre.
            GlowRing(fraction: value / 100,
                     value: value,
                     format: { "\(Int($0.rounded()))" },
                     color: color,
                     diameter: diameter,
                     lineWidth: lineWidth)
        } else {
            // Calibrating / no number yet: an empty track with a dash and a small "cal" marker. We render
            // "needs more data" as a dash, NEVER a number we did not earn.
            ZStack {
                Circle()
                    .stroke(StrandPalette.textPrimary.opacity(0.10),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                VStack(spacing: 1) {
                    Text("–")
                        .font(GlowRing.centerFont(diameter: diameter))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("cal")
                        .font(StrandFont.overlineScaled(8))
                        .tracking(0.5)
                        .foregroundStyle(color)
                }
            }
            .frame(width: diameter, height: diameter)
        }
    }
}

