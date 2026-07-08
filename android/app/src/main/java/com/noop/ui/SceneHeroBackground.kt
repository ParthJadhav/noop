package com.noop.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.noop.R
import java.util.Calendar

// MARK: - Scene Hero Background (NOOP day-cycle atmosphere behind the Today rings)
//
// Compose port of the iOS scene-hero treatment. A premium, NON-intrusive day-cycle illustration washed
// behind the top hero cards: full-WIDTH, aspect-fill, TOP-aligned so the sky shows, faded out top-down so
// it dissolves into the flat canvas behind the ring content. The scene is chosen from the CURRENT local
// hour and recomputed on recomposition (cheap — just a drawable lookup), so it changes through the day.
//
// HARD RULES honoured (standing):
//  - NO GLOW / no bloom. The scene is a flat image at a capped ~0.42 alpha, never a literal photo.
//  - The rings + WHITE numbers + labels MUST stay legible: a faint bottom-up dark scrim sits UNDER the
//    ring content so a bright midday scene never washes out the white text. No tinting of the rest of
//    the screen — this is confined to the hero region (the caller clips it to the rounded card).
//  - Reuses the [DayPart]/hour helper convention from TimeOfDayBackground.kt (clock-derived).
//
// HOUR -> SCENE map (local hour 0..23), per the placed day-cycle assets:
//   0,1,2,3,4 -> scene1 (deep night); 5 -> scene2; 6 -> scene3; 7 -> scene6; 8,9 -> scene7 (sunrise);
//   10,11 -> scene8 (day); 12,13,14,15,16 -> scene10 (bright midday); 17,18 -> scene9 (sunset);
//   19,20 -> scene5 (dusk); 21,22,23 -> scene4 (night + moon).

/** The scene drawable id for a local [hour] (0..23), per the placed day-cycle assets. */
internal fun sceneDrawableForHour(hour: Int): Int {
    val h = ((hour % 24) + 24) % 24
    return when (h) {
        in 0..4 -> R.drawable.scene1
        5 -> R.drawable.scene2
        6 -> R.drawable.scene3
        7 -> R.drawable.scene6
        8, 9 -> R.drawable.scene7
        10, 11 -> R.drawable.scene8
        in 12..16 -> R.drawable.scene10
        17, 18 -> R.drawable.scene9
        19, 20 -> R.drawable.scene5
        else -> R.drawable.scene4 // 21, 22, 23
    }
}

/** The scene drawable id for the current clock hour. */
internal fun currentSceneDrawable(): Int =
    sceneDrawableForHour(Calendar.getInstance().get(Calendar.HOUR_OF_DAY))

/**
 * Place a subtle day-cycle scene behind this content as an atmospheric wash. The scene fills the WIDTH
 * (aspect-fill, TOP-aligned so the sky shows), fades out top-down (fully visible at the top → fully
 * transparent ~70% down) and is capped at [maxAlpha] so it reads as a premium wash, never a photo. A
 * faint bottom-up dark [scrim] sits under the content so the white ring numbers stay legible on a bright
 * scene. Decorative — carries no semantics. Mirrors the iOS scene-hero background.
 *
 * Clip the caller's Box to its rounded shape (the existing hero Box already does
 * `.clip(RoundedCornerShape(...))`), and place this BEFORE the content so it paints behind it.
 *
 * @param drawable scene resource id; defaults to the current clock hour's scene.
 * @param maxAlpha overall opacity cap for the scene image (premium wash, never a literal photo).
 * @param fadeEndFraction the fraction of the height by which the scene has fully faded to transparent.
 * @param scrim whether to lay a faint bottom-up dark scrim under the content for ring-number contrast.
 */
@Composable
fun Modifier.sceneHeroBackground(
    drawable: Int = currentSceneDrawable(),
    maxAlpha: Float = 0.42f,
    fadeEndFraction: Float = 0.72f,
    scrim: Boolean = true,
): Modifier = this.then(SceneHeroBackgroundModifier(drawable, maxAlpha, fadeEndFraction, scrim))

/** Composable form for callers that prefer a child layer over a modifier — fills the parent. */
@Composable
fun SceneHeroBackground(
    modifier: Modifier = Modifier,
    drawable: Int = currentSceneDrawable(),
    maxAlpha: Float = 0.42f,
    fadeEndFraction: Float = 0.72f,
    scrim: Boolean = true,
) {
    Box(modifier = modifier.fillMaxSize().sceneHeroBackground(drawable, maxAlpha, fadeEndFraction, scrim))
}

/**
 * The backing modifier: draws the scene image (aspect-fill, top-aligned) UNDER the content, fades it
 * top-down by painting an OPAQUE canvas-coloured ([Palette.surfaceBase]) gradient over its lower part, then
 * (optionally) lays a faint bottom dark scrim for ring-number contrast — all before `drawContent()`.
 *
 * Why no saveLayer / BlendMode.DstIn: that earlier approach left the scene invisible. A `saveLayer` +
 * `DstIn` mask is fragile inside `drawWithContent` (the layer bounds + the painter's own alpha-compositing
 * interact badly, and the DstIn rect could wipe the whole layer), and `painter.intrinsicSize` can come back
 * `Unspecified` for a freshly-decoded vector/large bitmap — in which case the old `drawH` fell back to the
 * box height and the image drew letterboxed/empty. This version is the robust Compose idiom the task calls
 * for: draw the bitmap at the capped alpha covering the full WIDTH (height derived to ALWAYS cover the box,
 * top-aligned so the sky shows), then fade it by OVER-painting the canvas colour (a normal source-over
 * gradient — no blend modes), exactly how the rest of the screen dissolves into the flat canvas.
 */
@Composable
private fun Modifier.SceneHeroBackgroundModifier(
    drawable: Int,
    maxAlpha: Float,
    fadeEndFraction: Float,
    scrim: Boolean,
): Modifier {
    val painter = painterResource(drawable)
    val dark = !Palette.isLight
    val canvas = Palette.surfaceBase
    return this
        .clipToBounds()
        // PERF (#scroll-jank): the two verticalGradient Brushes + the aspect-fill drawH math were
        // rebuilt on every frame the hero composited (and a hero that sits in a scroll re-composites
        // constantly). Hoist the geometry + both Brushes into drawWithCache — keyed on the implicit size,
        // the drawable + its alphas — so they're built ONCE; onDrawWithContent just blits the painter,
        // over-paints the two pre-built gradients and draws the content. Pixel-identical: same aspect-fill
        // rule, same gradient stops/extents, same source-over order, same scrim gate.
        .drawWithCache {
            val h = size.height
            val fadeEnd = (h * fadeEndFraction).coerceIn(1f, h)
            val intrinsic = painter.intrinsicSize
            // Aspect-FILL on WIDTH: cover the full width, keep aspect, top-align (crop the bottom). If the
            // intrinsic size is Unspecified (NaN/≤0), fall back to a height that still COVERS the box rather
            // than letterboxing — so the scene is never blank.
            val drawW = size.width
            val drawH = if (intrinsic.width > 0f && intrinsic.height > 0f &&
                !intrinsic.width.isNaN() && !intrinsic.height.isNaN()
            ) {
                (drawW * (intrinsic.height / intrinsic.width)).coerceAtLeast(h)
            } else {
                h
            }
            val imageSize = Size(drawW, drawH)
            val fadeBrush = Brush.verticalGradient(
                colorStops = arrayOf(
                    0.0f to Color.Transparent,
                    0.45f to canvas.copy(alpha = 0.55f),
                    1.0f to canvas,
                ),
                startY = 0f,
                endY = fadeEnd,
            )
            val scrimBrush = if (scrim && dark) {
                Brush.verticalGradient(
                    colors = listOf(
                        Color.Transparent,
                        Color(0xFF0D1014).copy(alpha = 0.28f),
                    ),
                    startY = h * 0.55f,
                    endY = h,
                )
            } else {
                null
            }
            onDrawWithContent {
                // 1) The scene image, top-aligned (origin 0,0), at the capped alpha. clipToBounds crops the
                //    overflow below the hero. A plain source-over draw — no layer, no blend mode.
                with(painter) {
                    draw(size = imageSize, alpha = maxAlpha)
                }
                // 2) Top-down fade: OVER-paint the canvas colour so the lower scene dissolves into the flat
                //    canvas exactly like the iOS top-down mask. Source-over (no DstIn) — robust.
                drawRect(brush = fadeBrush)
                // 3) A faint bottom dark scrim so the white ring numbers + labels keep their contrast on a
                //    bright (midday) scene. Subtle, dark-mode only — no glow.
                if (scrimBrush != null) {
                    drawRect(brush = scrimBrush)
                }
                // 4) The actual content (rings, labels) on top — always fully legible.
                drawContent()
            }
        }
}

// MARK: - Scene SCREEN background (the scene as the PAGE backdrop — cards float OVER it)
//
// Compose port of the iOS `SceneScreenBackground`. The day-cycle scene anchored to the TOP of the SCREEN,
// behind the header + the rings hero — so it "forms part of the background" and the cards sit OVER it
// (the design direction). Full-WIDTH (aspect-fill), TOP-aligned so the sky shows, fading into the canvas
// ([Palette.surfaceBase]) over its lower portion (~92% down) so it dissolves before the dashboard cards, at
// a ~0.5 image alpha. A faint dark scrim under the VERY top keeps the white header text legible on a bright
// sky. Place it edge-to-edge as a TOP-anchored screen background behind the scroll content (the caller
// bleeds it full-width and up behind the status bar). No glow.

/** How far down the screen the scene reaches before it has fully faded into the flat canvas. */
private val SceneScreenHeightDefault: Dp = 520.dp

/**
 * Draw the day-cycle SCREEN backdrop behind this content: the [drawable] scene (current hour by default),
 * full-width and top-aligned, faded top-down into [Palette.surfaceBase] by [fadeEndFraction] of the
 * backdrop band, capped at [maxAlpha], with a faint top dark scrim for header legibility. Mirrors the iOS
 * `SceneScreenBackground`. Decorative — carries no semantics. Place it BEFORE the content so it paints
 * behind it (e.g. as the first child of a Box, or via [SceneScreenBackground]).
 *
 * Unlike [sceneHeroBackground] this is NOT clipped to a card and lays NO bottom scrim — it is the page
 * backdrop the whole top region floats over, fading into the canvas rather than into a rounded hero.
 *
 * @param bandHeightPx the pixel height over which the scene reaches before it has fully faded to the
 *   canvas. The fade band is independent of the (taller) layout box, so the scene always dissolves into
 *   the flat canvas at the SAME on-screen distance regardless of how tall the wrapping Box is.
 */
@Composable
fun Modifier.sceneScreenBackground(
    drawable: Int = currentSceneDrawable(),
    maxAlpha: Float = 0.95f,
    fadeEndFraction: Float = 0.92f,
    bandHeightPx: Float = Float.NaN,
): Modifier {
    val painter = painterResource(drawable)
    val canvas = Palette.surfaceBase
    val dark = !Palette.isLight
    return this
        .clipToBounds()
        // PERF (#scroll-jank): the Today screen-level scene backdrop — its fade + top-scrim Brushes and
        // the aspect-fill drawH math were rebuilt every frame the backdrop was re-issued under the
        // scrolling content. Hoist them into drawWithCache (keyed on the implicit size + drawable +
        // alphas); onDrawBehind just blits the painter and over-paints the two pre-built gradients.
        // Pixel-identical: same band/fade math, same gradient stops, same scrim gate + extent.
        .drawWithCache {
            val h = size.height
            // The fade band: the scene fully dissolves into the canvas by `band * fadeEndFraction`. When no
            // explicit band is given, use the full box height (the caller already sizes the Box to the
            // backdrop band, ~520dp). Clamped so a tiny/zero box never divides by zero.
            val band = if (bandHeightPx.isNaN() || bandHeightPx <= 0f) h else bandHeightPx
            val fadeEnd = (band * fadeEndFraction).coerceIn(1f, h.coerceAtLeast(1f))
            val intrinsic = painter.intrinsicSize
            // Aspect-FILL on WIDTH: cover the full width, keep aspect, top-align (crop the bottom). If the
            // intrinsic size is Unspecified (NaN/≤0), fall back to a height that still COVERS the box rather
            // than letterboxing — so the scene is never blank.
            val drawW = size.width
            val drawH = if (intrinsic.width > 0f && intrinsic.height > 0f &&
                !intrinsic.width.isNaN() && !intrinsic.height.isNaN()
            ) {
                (drawW * (intrinsic.height / intrinsic.width)).coerceAtLeast(band)
            } else {
                band
            }
            val imageSize = Size(drawW, drawH)
            val fadeBrush = Brush.verticalGradient(
                colorStops = arrayOf(
                    0.0f to Color.Transparent,
                    0.34f to canvas.copy(alpha = 0.10f),
                    0.62f to canvas.copy(alpha = 0.60f),
                    1.0f to canvas,
                ),
                startY = 0f,
                endY = fadeEnd,
            )
            val scrimBrush = if (dark) {
                Brush.verticalGradient(
                    colors = listOf(
                        Color(0xFF0D1014).copy(alpha = 0.12f),
                        Color.Transparent,
                    ),
                    startY = 0f,
                    endY = (band * 0.22f).coerceIn(1f, h.coerceAtLeast(1f)),
                )
            } else {
                null
            }
            onDrawBehind {
                // 1) The scene image, top-aligned (origin 0,0), at the capped alpha. A plain source-over
                //    draw — no layer, no blend mode (the same robust idiom as the hero background).
                with(painter) {
                    draw(size = imageSize, alpha = maxAlpha)
                }
                // 2) Top-down fade: OVER-paint the canvas colour so the lower scene dissolves into the flat
                //    canvas before the cards — exactly like the iOS top-down mask. Source-over (no DstIn).
                drawRect(brush = fadeBrush)
                // 3) A faint dark scrim under the VERY top so the white header text (Today + the date + the
                //    top-bar icons) stays legible on a bright (midday) sky. Subtle, dark-mode only — no glow.
                if (scrimBrush != null) {
                    drawRect(brush = scrimBrush)
                }
            }
        }
}

/**
 * Composable child-layer form of [sceneScreenBackground] for callers that prefer a layer over a modifier.
 * Fills the parent's WIDTH and stands [height] tall (the backdrop band; the scene fades to the canvas
 * within it). Drop it as the FIRST child of the screen's wrapping Box (anchored top) so the scroll content
 * floats over it. Mirrors the iOS `SceneScreenBackground` view.
 */
@Composable
fun SceneScreenBackground(
    modifier: Modifier = Modifier,
    drawable: Int = currentSceneDrawable(),
    height: Dp = SceneScreenHeightDefault,
    maxAlpha: Float = 0.95f,
    fadeEndFraction: Float = 0.92f,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(height)
            .sceneScreenBackground(drawable, maxAlpha, fadeEndFraction),
    )
}
