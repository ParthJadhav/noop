import SwiftUI

// MARK: - Scene Hero Background — the day-cycle illustration behind the hero rings
//
// A premium atmospheric wash that fades from the top down behind the top hero cards, picked from
// ten hand-painted day-cycle illustrations by the CURRENT local hour. It REPLACES the procedural
// `TimeOfDayBackground` on the HERO only — the scene IS the atmosphere there now — while the rest of
// the screen stays on the flat canvas.
//
// HARD RULES honoured here (standing):
//  - NO GLOW / no bloom / no blur halos. The scene is a flat image masked by a linear gradient.
//  - SUBTLE: the image caps at ~0.42 opacity so it reads as an atmospheric wash, never a literal photo.
//    A faint bottom-up dark scrim under the ring content keeps the white ring numbers + labels crisp
//    even over a bright midday scene.
//  - TOKENS first: the dark scrim is built from `StrandPalette.surfaceBase`, the canvas token.
//  - Each scene asset is PORTRAIT (~0.71 ratio), sky at the top — so we scale to FILL the width and
//    TOP-align, showing the sky and cropping the overflow, then clip to the hero's rounded-rect bounds.
//  - The scene is chosen on appear (cheap); it recomputes when the hour changes.

// MARK: - Hour → scene

/// Maps a local hour (0...23) to one of the ten day-cycle illustration asset names ("scene1"..."scene10").
/// Hand-tuned so the sky's light matches the time of day:
///   0–4 deep night · 5 first light · 6 dawn · 7 early morning · 8–9 sunrise · 10–11 day ·
///   12–16 bright midday · 17–18 sunset · 19–20 dusk · 21–23 night + moon.
public enum DayCycleScene {
    /// The asset name for a given hour. Defensive modulo so any hour value is safe.
    public static func assetName(hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        switch h {
        case 0, 1, 2, 3, 4: return "scene1"   // deep night
        case 5:             return "scene2"   // first light
        case 6:             return "scene3"   // dawn
        case 7:             return "scene6"   // early morning
        case 8, 9:          return "scene7"   // sunrise
        case 10, 11:        return "scene8"   // day
        case 12, 13, 14, 15, 16: return "scene10" // bright midday
        case 17, 18:        return "scene9"   // sunset
        case 19, 20:        return "scene5"   // dusk
        default:            return "scene4"   // 21–23 night + moon
        }
    }

    /// The asset name for *now*, from the system clock.
    public static var current: String {
        assetName(hour: Calendar.current.component(.hour, from: Date()))
    }

    /// Whether the hour's scene is a bright one (midday/day) — the hero then warrants a slightly firmer
    /// bottom scrim so the white ring numbers stay legible over the brighter sky.
    public static func isBright(hour: Int) -> Bool {
        let h = ((hour % 24) + 24) % 24
        return (8...16).contains(h)
    }
}

// MARK: - Scene hero background view

/// A full-width day-cycle scene placed at the TOP of the hero region, aspect-filled and top-aligned so
/// the sky shows, masked by a top-down fade to fully transparent by ~70% down, capped at ~0.42 opacity,
/// over a faint bottom-up dark scrim that protects the ring content's contrast. Clipped to the hero's
/// rounded-rect bounds. Drop it behind the hero via `.sceneHeroBackground()`.
public struct SceneHeroBackground: View {

    /// The local hour driving which scene shows (0...23). Defaults to the current clock hour.
    private let hour: Int

    public init(hour: Int = Calendar.current.component(.hour, from: Date())) {
        self.hour = hour
    }

    /// Overall image opacity ceiling — atmospheric wash, never a literal photo.
    private let imageOpacityCap: Double = 0.42
    /// The hero's rounded-rect corner radius (matches the card the scene sits behind).
    private let corner: CGFloat = NoopMetrics.cardRadius

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // The day-cycle scene: aspect-FILL the width, TOP-aligned so the sky shows; overflow is
                // cropped by the clip below. A flat image — no blur, no glow.
                Image(DayCycleScene.assetName(hour: hour))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, alignment: .top)
                    .frame(width: w, height: h, alignment: .top)
                    .clipped()
                    // TOP-DOWN FADE: fully visible at the very top, fading to fully transparent by ~70%
                    // down the hero, so it never crowds the rings/numbers lower in the card.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0.0),
                                .init(color: .white.opacity(0.85), location: 0.30),
                                .init(color: .white.opacity(0.35), location: 0.55),
                                .init(color: .clear, location: 0.72),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .opacity(imageOpacityCap)

                // A faint bottom-up dark scrim built from the canvas token, so white ring numbers + labels
                // stay crisp even over a bright midday sky. Firmer for bright scenes, lighter otherwise.
                LinearGradient(
                    colors: [.clear, StrandPalette.surfaceBase.opacity(DayCycleScene.isBright(hour: hour) ? 0.55 : 0.32)],
                    startPoint: .center, endPoint: .bottom
                )
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .ignoresSafeArea(edges: [])      // confined to the hero region, not full-bleed
        .allowsHitTesting(false)          // pure backdrop — never steals touches
        .accessibilityHidden(true)        // decorative; invisible to VoiceOver
    }
}

// MARK: - Scene SCREEN background — the scene as the PAGE backdrop (cards float OVER it)

/// The day-cycle scene anchored to the TOP of the SCREEN, behind the header + hero card — so it "forms
/// part of the background" and the cards sit OVER it (the design direction). Aspect-filled to the full width,
/// top-aligned (sky shows), fading into the canvas over its lower portion so it dissolves before the
/// dashboard cards. A faint dark scrim under the very top keeps white header text legible on a bright sky.
/// Place it edge-to-edge as a top-anchored screen background (the caller ignores safe area). No glow.
public struct SceneScreenBackground: View {
    private let hour: Int
    /// How far down the screen the scene reaches before it has fully faded into the canvas.
    public var height: CGFloat

    public init(hour: Int = Calendar.current.component(.hour, from: Date()), height: CGFloat = 600) {
        self.hour = hour
        self.height = height
    }

    /// Backdrop opacity, near-full so the scene reads VIVIDLY (by design). The dark hero CARD floating over it
    /// is what keeps the rings/data legible, so the scene itself doesn't need to be muted.
    private let imageOpacityCap: Double = 0.95

    public var body: some View {
        Image(DayCycleScene.assetName(hour: hour))
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .top)
            .clipped()
            // Fade into the canvas over the lower portion so it dissolves before the dashboard cards.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0.0),
                        .init(color: .white.opacity(0.9), location: 0.34),
                        .init(color: .white.opacity(0.4), location: 0.62),
                        .init(color: .clear, location: 0.92),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .opacity(imageOpacityCap)
            // A whisper of dark under the very top for header legibility — kept light so the scene reads at
            // near-full vividness (the design calls for ~95%, not muted).
            .overlay(
                LinearGradient(
                    colors: [StrandPalette.surfaceBase.opacity(0.12), .clear],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.22)
                )
            )
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Modifier + convenience

public extension View {
    /// Place the day-cycle `SceneHeroBackground` behind this content (the hero region). Defaults to the
    /// current clock hour; the scene recomputes when the hour changes (cheap, on appear is fine).
    ///
    ///     heroSection.sceneHeroBackground()            // current hour
    ///     heroSection.sceneHeroBackground(hour: 20)    // pinned hour (previews)
    func sceneHeroBackground(hour: Int = Calendar.current.component(.hour, from: Date())) -> some View {
        background(SceneHeroBackground(hour: hour))
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Scene hero — sample hours") {
    VStack(spacing: 16) {
        ForEach([2, 6, 8, 13, 18, 22], id: \.self) { hr in
            ZStack {
                VStack(spacing: 6) {
                    Text("hour \(hr)")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text("88")
                        .font(StrandFont.rounded(36, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            .frame(height: 96)
            .sceneHeroBackground(hour: hr)
        }
    }
    .padding(18)
    .frame(width: 360, height: 760)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
