package com.noop.ui

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.translate
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

// MARK: - Renderers (pure DrawScope drawing) — Compose port of Strand/Liquid/LiquidPrimitives.swift
//
// The signature liquid elements, drawn directly onto a DrawScope: the circular vessel
// gauge, the horizontal tube, and the live heart-rate thread. Each takes the DrawScope
// (as the receiver), the canvas size, a LiquidSim (vessel/tube), the current seconds
// `now`, and a `tint` colour supplied by the call site. The physics (LiquidSim,
// liquidWave / liquidChordHW / liquidCurl) live in LiquidSim.kt in this same package.
//
// This is a 1:1 behavioural port of the SwiftUI GraphicsContext version: same constants,
// same layering order, same magic numbers. SwiftUI context copies that translate/rotate
// independently are expressed here as separately nested translate { rotate { clipPath { } } }
// DrawScope scopes so their transforms never leak into one another. Swift rotate() is in
// radians; Compose rotate() is in degrees, so every rotation is converted. Rotations pivot
// about the current origin (Offset.Zero) to match Swift's rotate-about-origin semantics.

object LiquidRender {

    // Structural near-blacks (ported as-is from the Swift renderer's literal rgba wells).
    private val wellInk = Color(red = 10f / 255f, green = 11f / 255f, blue = 16f / 255f, alpha = 0.55f)
    private val tubeTrack = Color(red = 14f / 255f, green = 14f / 255f, blue = 18f / 255f, alpha = 1f)

    // Colour helpers on `tint` (mirror LiquidCore.swift's liquidDarker / liquidMix). These operate
    // on the passed-in tint colour, not on any physics — kept here so the renderer is self-contained.

    /** Multiply toward black by `t` (the mock's `shade`). Alpha forced opaque, matching Swift. */
    private fun Color.liquidDarker(t: Double): Color {
        val f = t.coerceIn(0.0, 1.0).toFloat()
        return Color(red = red * (1f - f), green = green * (1f - f), blue = blue * (1f - f), alpha = 1f)
    }

    /** Linear-interpolate toward `other` by `t`, opaque (mirrors liquidMix). */
    private fun Color.liquidMix(other: Color, t: Double): Color {
        val f = t.coerceIn(0.0, 1.0).toFloat()
        return Color(
            red = red + (other.red - red) * f,
            green = green + (other.green - green) * f,
            blue = blue + (other.blue - blue) * f,
            alpha = 1f,
        )
    }

    // Not `const` — a `const val` initializer must be a compile-time constant, and Math.PI (a Java
    // static field) is not accepted there. A plain `val` computes it once at class-load, which is fine.
    private val RAD2DEG = 180.0 / Math.PI

    /**
     * A circular vessel of liquid filled to `sim.level`, tinted, with parallax slosh, a light
     * band that follows tilt, surface glints, flake and droplets. Draws onto the receiver DrawScope.
     */
    fun DrawScope.vessel(size: Size, sim: LiquidSim, now: Double, tint: Color) {
        val R = min(size.width.toDouble(), size.height.toDouble()) / 2.0 - 1.5
        val ext = R * 1.8
        val cx = size.width.toDouble() / 2.0
        val cy = size.height.toDouble() / 2.0
        // The dark "well" ellipse and rim are drawn in the centred frame; the outer rim after the body.
        val well = Path().apply {
            addOval(Rect(left = (cx - R).toFloat(), top = (cy - R).toFloat(), right = (cx + R).toFloat(), bottom = (cy + R).toFloat()))
        }
        drawPath(well, color = wellInk)

        // Everything below is drawn in the centred coordinate system (origin at the vessel centre),
        // clipped to the circle — the Swift `body` context (ctx.translateBy(cx,cy) then clip).
        translate(left = cx.toFloat(), top = cy.toFloat()) {
            val wellCentred = Path().apply {
                addOval(Rect(left = (-R).toFloat(), top = (-R).toFloat(), right = R.toFloat(), bottom = R.toFloat()))
            }
            clipPath(wellCentred) {
                val lv = sim.level
                if (lv > 0.004) {
                    val sy = R * (1.0 - 2.0 * min(0.985, lv))
                    val amp = (0.018 + sim.energy * 0.09) * R

                    // Build a filled wave polygon for a wave-height function `w`.
                    fun wavePolygon(w: (Double) -> Double): Path {
                        val p = Path()
                        p.moveTo((-ext).toFloat(), w(-ext).toFloat())
                        var x = -ext + 4
                        while (x <= ext) { p.lineTo(x.toFloat(), w(x).toFloat()); x += 4 }
                        p.lineTo(ext.toFloat(), w(ext).toFloat())
                        p.lineTo(ext.toFloat(), (R * 2.4).toFloat())
                        p.lineTo((-ext).toFloat(), (R * 2.4).toFloat())
                        p.close()
                        return p
                    }
                    fun surfaceLine(w: (Double) -> Double): Path {
                        val p = Path()
                        p.moveTo((-ext).toFloat(), w(-ext).toFloat())
                        var x = -ext + 4
                        while (x <= ext) { p.lineTo(x.toFloat(), w(x).toFloat()); x += 4 }
                        p.lineTo(ext.toFloat(), w(ext).toFloat())
                        return p
                    }

                    // back parallax layer
                    val syB = sy - R * 0.04
                    val hwB = liquidChordHW(R, syB)
                    val wB: (Double) -> Double = {
                        liquidWave(it, amp, R, hwB, liquidCurl(sim.abv), sim.p1 * 0.92 + 2.1, sim.p2 * 0.9 + 1.3, 1.35)
                    }
                    translate(left = 0f, top = syB.toFloat()) {
                        rotate(degrees = (sim.ab * RAD2DEG).toFloat(), pivot = Offset.Zero) {
                            drawPath(wavePolygon(wB), color = tint.copy(alpha = 0.28f))
                        }
                    }

                    // main body
                    val hw = liquidChordHW(R, sy)
                    val w: (Double) -> Double = {
                        liquidWave(it, amp, R, hw, liquidCurl(sim.av), sim.p1, sim.p2, 1.0)
                    }
                    translate(left = 0f, top = sy.toFloat()) {
                        rotate(degrees = (sim.a * RAD2DEG).toFloat(), pivot = Offset.Zero) {
                            val bodyWave = wavePolygon(w)
                            drawPath(
                                bodyWave,
                                brush = Brush.linearGradient(
                                    colors = listOf(tint.copy(alpha = 0.74f), tint.liquidDarker(0.28).copy(alpha = 0.80f)),
                                    start = Offset(0f, (-amp).toFloat()),
                                    end = Offset(0f, (R * 1.7).toFloat()),
                                ),
                            )

                            // a sheet of light gliding across as you tilt (clipped to the wave polygon)
                            clipPath(bodyWave) {
                                val bandX = -sim.a * R * 2.2 + sin(now * 0.3) * R * 0.15
                                drawRect(
                                    brush = Brush.linearGradient(
                                        colors = listOf(Color.White.copy(alpha = 0f), Color.White.copy(alpha = 0.06f), Color.White.copy(alpha = 0f)),
                                        start = Offset((bandX - R * 1.2).toFloat(), 0f),
                                        end = Offset((bandX + R * 1.2).toFloat(), 0f),
                                    ),
                                    topLeft = Offset((-R * 2.4).toFloat(), (-R * 2.4).toFloat()),
                                    size = Size((R * 4.8).toFloat(), (R * 4.8).toFloat()),
                                )
                            }

                            // surface sheen + glints + line
                            drawRect(
                                brush = Brush.linearGradient(
                                    colors = listOf(Color.White.copy(alpha = 0.09f), Color.White.copy(alpha = 0f)),
                                    start = Offset(0f, 0f),
                                    end = Offset(0f, (R * 0.15).toFloat()),
                                ),
                                topLeft = Offset((-ext).toFloat(), 0f),
                                size = Size((ext * 2).toFloat(), (R * 0.15).toFloat()),
                            )
                            var gx = -hw
                            while (gx <= hw) {
                                val slope = (w(gx + 3) - w(gx - 3)) / 6.0
                                if (abs(slope) < 0.05) {
                                    val o = 0.22 * (1.0 - abs(slope) / 0.05)
                                    drawRect(
                                        color = Color.White.copy(alpha = o.toFloat()),
                                        topLeft = Offset((gx - 2).toFloat(), (w(gx) - 0.8).toFloat()),
                                        size = Size(4f, 1.4f),
                                    )
                                }
                                gx += 6
                            }
                            drawPath(
                                surfaceLine(w),
                                color = Color.White.copy(alpha = 0.45f),
                                style = Stroke(width = 1.3f),
                            )

                            // droplets
                            for (b in sim.drops) {
                                val rr = max(0.7, b.r * R)
                                val dp = Path().apply {
                                    addOval(
                                        Rect(
                                            left = (b.x * R - rr).toFloat(), top = (b.y * R - rr).toFloat(),
                                            right = (b.x * R + rr).toFloat(), bottom = (b.y * R + rr).toFloat(),
                                        ),
                                    )
                                }
                                drawPath(dp, color = Color.White.copy(alpha = (min(0.55, b.life * 0.5) * 0.5).toFloat()))
                            }
                        }
                    }

                    // suspended flake (drawn in the centred `body` frame — NOT the sy/rotate frame —
                    // only when inside the liquid). Square flecks, three kinds, with a sparkle.
                    val sa = sin(sim.a)
                    val ca = cos(sim.a)
                    for (f in sim.flecks) {
                        val fx = f.x * R
                        val fy = f.y * R
                        if (fx * fx + fy * fy > R * R * 0.9) continue
                        if (-fx * sa + (fy - sy) * ca < R * 0.02) continue
                        val sVal = sin(f.ph + fx * 0.12 + sim.a * 5.0 + now * f.sp)
                        val spark = max(0.0, sVal).pow(10)
                        val sz = 0.7 + f.z * 1.0 + spark * 1.4
                        val shade: Color = when (f.kind) {
                            2 -> Color(red = 8f / 255f, green = 10f / 255f, blue = 13f / 255f, alpha = (0.12 + spark * 0.22).toFloat().coerceIn(0f, 1f))
                            1 -> tint.liquidMix(Color.White, 0.55).copy(alpha = (0.10 + spark * 0.8).toFloat().coerceIn(0f, 1f))
                            else -> Color.White.copy(alpha = (0.08 * f.z + spark * 0.85).toFloat().coerceIn(0f, 1f))
                        }
                        drawRect(
                            color = shade,
                            topLeft = Offset((fx - sz / 2).toFloat(), (fy - sz / 2).toFloat()),
                            size = Size(sz.toFloat(), sz.toFloat()),
                        )
                    }
                }

                // inner top shadow
                drawRect(
                    brush = Brush.linearGradient(
                        colors = listOf(Color.Black.copy(alpha = 0.30f), Color.Black.copy(alpha = 0f)),
                        start = Offset(0f, (-R).toFloat()),
                        end = Offset(0f, (-R * 0.30).toFloat()),
                    ),
                    topLeft = Offset((-R).toFloat(), (-R).toFloat()),
                    size = Size((2 * R).toFloat(), (R * 0.75).toFloat()),
                )
                // soft top-left highlight (radial)
                val hiRect = Rect(
                    left = (-R * 0.72).toFloat(), top = (-R * 0.78).toFloat(),
                    right = (-R * 0.72 + R * 0.9).toFloat(), bottom = (-R * 0.78 + R * 0.5).toFloat(),
                )
                val hiPath = Path().apply { addOval(hiRect) }
                drawPath(
                    hiPath,
                    brush = Brush.radialGradient(
                        colors = listOf(Color.White.copy(alpha = 0.09f), Color.White.copy(alpha = 0f)),
                        center = Offset((-R * 0.27).toFloat(), (-R * 0.5).toFloat()),
                        radius = (R * 0.55).toFloat(),
                    ),
                )
            }
        }

        // rim (outermost, unclipped — in the original page-space `well`)
        drawPath(well, color = tint.copy(alpha = 0.22f), style = Stroke(width = 1.25f))
    }

    /** A horizontal capsule tube filled to `frac`; tilt pushes the liquid along it. */
    fun DrawScope.tube(size: Size, sim: LiquidSim, now: Double, frac: Double, tint: Color) {
        val w = size.width.toDouble()
        val h = size.height.toDouble()
        val r = h / 2.0
        val outline = Path().apply {
            addRoundRect(
                RoundRect(
                    Rect(left = 0.5f, top = 0.5f, right = (w - 0.5).toFloat(), bottom = (h - 0.5).toFloat()),
                    CornerRadius(r.toFloat(), r.toFloat()),
                ),
            )
        }
        drawPath(outline, color = tubeTrack)
        drawPath(outline, color = Color.White.copy(alpha = 0.07f), style = Stroke(width = 1f))

        clipPath(outline) {
            val shift = -sim.a * h * 1.3
            val edge = max(r * 0.8, min(w - 2.0, frac * (w - 4.0) + shift))
            val bulge = r * 0.6 + sin(sim.p1 * 2.0) * sim.energy * h * 0.3 - 0.01 * h * 6.0
            val p = Path()
            p.moveTo(0f, 0f)
            p.lineTo((edge - r * 0.3).toFloat(), 0f)
            p.quadraticBezierTo((edge + bulge).toFloat(), (h / 2.0).toFloat(), (edge - r * 0.3).toFloat(), h.toFloat())
            p.lineTo(0f, h.toFloat())
            p.close()
            drawPath(
                p,
                brush = Brush.linearGradient(
                    colors = listOf(tint.copy(alpha = 0.84f), tint.liquidDarker(0.28).copy(alpha = 0.86f)),
                    start = Offset(0f, 0f),
                    end = Offset(0f, h.toFloat()),
                ),
            )
            drawRect(
                color = Color.White.copy(alpha = 0.12f),
                topLeft = Offset(2f, 1.2f),
                size = Size(max(0.0, edge - r * 0.6).toFloat(), 1f),
            )
            for (i in 0 until min(8, sim.flecks.size)) {
                val f = sim.flecks[i]
                val spark = max(0.0, sin(f.ph + sim.a * 5.0 + now * f.sp)).pow(10)
                if (spark < 0.08) continue
                val fx = 3.0 + (f.x + 1.05) / 2.1 * max(1.0, edge - 8.0)
                drawRect(
                    color = Color.White.copy(alpha = (spark * 0.6).toFloat().coerceIn(0f, 1f)),
                    topLeft = Offset(fx.toFloat(), (h * 0.15 + f.z * h * 0.7).toFloat()),
                    size = Size((1 + spark).toFloat(), (1 + spark).toFloat()),
                )
            }
        }
    }

    /** The live heart-rate curve as a glowing liquid thread with a travelling glint. */
    fun DrawScope.thread(size: Size, values: List<Double>, now: Double, tint: Color) {
        if (values.size < 2) return
        val w = size.width.toDouble()
        val h = size.height.toDouble()
        val pad = 10.0
        var mn = Double.MAX_VALUE
        var mx = -Double.MAX_VALUE
        for (v in values) { mn = min(mn, v); mx = max(mx, v) }
        val span = max(10.0, mx - mn)
        val n = values.size
        fun px(i: Int): Double = pad + i.toDouble() * (w - 2 * pad) / (n - 1).toDouble()
        fun py(v: Double): Double = h - pad - (v - mn) / span * (h - 2 * pad)
        fun curve(): Path {
            val p = Path()
            p.moveTo(px(0).toFloat(), py(values[0]).toFloat())
            for (i in 1 until (n - 1)) {
                val xc = (px(i) + px(i + 1)) / 2.0
                val yc = (py(values[i]) + py(values[i + 1])) / 2.0
                p.quadraticBezierTo(px(i).toFloat(), py(values[i]).toFloat(), xc.toFloat(), yc.toFloat())
            }
            p.lineTo(px(n - 1).toFloat(), py(values[n - 1]).toFloat())
            return p
        }
        drawPath(
            curve(),
            color = tint.copy(alpha = 0.9f),
            style = Stroke(width = 2.4f, cap = StrokeCap.Round, join = StrokeJoin.Round),
        )
        // travelling glint — Swift uses truncatingRemainder (sign of the dividend); Kotlin `rem` (== %)
        // is the exact twin. `now` is a from-zero accumulator so the value is always non-negative here.
        val phase = -(now * 55).rem(414.0)
        drawPath(
            curve(),
            color = Color.White.copy(alpha = 0.55f),
            style = Stroke(
                width = 1.1f,
                cap = StrokeCap.Round,
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(14f, 400f), phase.toFloat()),
            ),
        )
        // endpoint pulse
        val ex = px(n - 1)
        val ey = py(values[n - 1])
        val pr = 3.0 + sin(now * 6) * 1.1
        val halo = Path().apply {
            addOval(
                Rect(
                    left = (ex - pr - 4).toFloat(), top = (ey - pr - 4).toFloat(),
                    right = (ex + pr + 4).toFloat(), bottom = (ey + pr + 4).toFloat(),
                ),
            )
        }
        drawPath(halo, color = tint.copy(alpha = 0.15f))
        val core = Path().apply {
            addOval(
                Rect(
                    left = (ex - pr).toFloat(), top = (ey - pr).toFloat(),
                    right = (ex + pr).toFloat(), bottom = (ey + pr).toFloat(),
                ),
            )
        }
        drawPath(core, color = tint)
    }
}
