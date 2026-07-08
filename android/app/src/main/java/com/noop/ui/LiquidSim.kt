package com.noop.ui

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

// MARK: - LiquidSim / wave sampler — Compose port of Strand/Liquid/LiquidCore.swift
//
// The physics foundation shared by every liquid element: a spring-damped surface that stays
// level with the world as the device tilts, layered travelling waves, suspended metal flake,
// and splash droplets. Pure value maths so a Compose Canvas can step it each frame from its
// draw lambda. This is a 1:1 behavioural port of the Swift `LiquidSim` + wave helpers — every
// spring / energy / phase constant and integration step is identical, so the motion matches iOS.
//
// (Swift structs are value types mutated by index; Kotlin uses reference-type Fleck/Drop classes
// with `var` fields, mutated in place — behaviourally identical, just without the index dance.)

/** A single suspended metal fleck, in R-normalised circle coords. */
class Fleck(
    var x: Double,
    var y: Double,
    var z: Double,
    var ph: Double,
    var sp: Double,
    var kind: Int,
)

/** A single splash droplet, R-normalised. */
class Drop(
    var x: Double,
    var y: Double,
    var vy: Double,
    var r: Double,
    var w: Double,
    var life: Double,
)

/**
 * Mutable physics for one body of liquid. Stepped once per frame from a Canvas draw lambda.
 * Faithful port of the Swift `LiquidSim` — same fields, same constants, same step order.
 */
class LiquidSim(target: Double, private val reduceMotion: Boolean = false) {
    // fill
    var level: Double = 0.0
    var target: Double = target.coerceIn(0.0, 1.0)
    // front + back surface springs (the parallax slosh)
    var a: Double = 0.0
    var av: Double = 0.0
    var ab: Double = 0.0
    var abv: Double = 0.0
    // wave energy + phases
    var energy: Double = if (reduceMotion) 0.1 else 0.5
    var p1: Double = Random.nextDouble(0.0, 7.0)
    var p2: Double = Random.nextDouble(0.0, 7.0)
    // suspended flake + splash droplets
    val flecks: MutableList<Fleck> = ArrayList(28)
    val drops: MutableList<Drop> = ArrayList()

    private var nudge: Double = 2.0 + Random.nextDouble(0.0, 5.0)
    private var lastTime: Double? = null

    init {
        // fewer flecks per vessel: ~40% cheaper per-frame render, imperceptible at gauge size
        repeat(28) {
            val k = if (Random.nextDouble() < 0.2) 2 else if (Random.nextDouble() < 0.44) 1 else 0
            flecks.add(
                Fleck(
                    x = Random.nextDouble(-1.0, 1.0),
                    y = Random.nextDouble(-1.0, 1.0),
                    z = 0.35 + Random.nextDouble(0.0, 0.65),
                    ph = Random.nextDouble(0.0, 7.0),
                    sp = 0.4 + Random.nextDouble(0.0, 1.4),
                    kind = k,
                ),
            )
        }
    }

    // material constants (the locked "liquid glass + flake")
    private val kSpring = 31.0
    private val cSpring = 5.5
    private val kBack = 20.0
    private val cBack = 4.3
    private val phaseMul = 0.85

    /** Advance to absolute time `now` (seconds), chasing `target`, with world tilt. */
    fun step(now: Double, tilt: Double, target: Double) {
        this.target = target.coerceIn(0.0, 1.0)
        val last = lastTime
        val dt: Double = if (last != null) min(0.033, now - last) else 0.0
        lastTime = now
        if (dt <= 0.0) return

        val surfTarget = -tilt   // container one way, the surface stays level → the other
        av += (kSpring * (surfTarget - a) - cSpring * av) * dt
        a += av * dt; a = a.coerceIn(-0.6, 0.6)
        abv += (kBack * (surfTarget - ab) - cBack * abv) * dt
        ab += abv * dt; ab = ab.coerceIn(-0.66, 0.66)

        energy = min(1.2, energy + (abs(av) + abs(abv)) * dt * 0.07)
        nudge -= dt
        if (nudge <= 0.0) {
            nudge = 3.5 + Random.nextDouble(0.0, 5.0)
            if (!reduceMotion) {
                av += (if (Random.nextBoolean()) 1.0 else -1.0) * (0.05 + Random.nextDouble(0.0, 0.08))
                energy = min(1.2, energy + 0.05)
            }
        }
        val d = this.target - level
        if (abs(d) > 0.0004) {
            level += d * min(1.0, dt * 2.6)
            energy = min(1.2, energy + abs(d) * dt * 6.0)
        }
        val speed = (1.0 + energy * 2.2) * phaseMul
        p1 += dt * 2.1 * speed
        p2 += dt * 3.3 * speed
        energy *= exp(-dt * 1.5)
        if (!reduceMotion && energy < 0.025) energy = 0.025

        for (dp in drops) {
            dp.y -= dp.vy * dt
            dp.x += sin(dp.y * 7.0 + dp.w) * 0.12 * dt
            dp.life -= dt
        }
        drops.removeAll { it.life <= 0.0 || it.y <= 0.03 }

        for (f in flecks) {
            f.x += (-av * 0.30 * f.z + sin(now * 0.35 + f.ph) * 0.015) * dt
            f.y += cos(now * 0.28 + f.ph * 1.3) * 0.012 * dt
            if (f.x > 1.05) f.x = -1.05 else if (f.x < -1.05) f.x = 1.05
            if (f.y > 1.05) f.y = -1.05 else if (f.y < -1.05) f.y = 1.05
        }
    }

    fun splash(n: Int) {
        val count = if (reduceMotion) min(n, 4) else n
        val depth = max(0.10, 2.0 * level * 0.9)
        repeat(count) {
            drops.add(
                Drop(
                    x = Random.nextDouble(-1.0, 1.0) * 0.5,
                    y = depth * (0.45 + Random.nextDouble(0.0, 0.5)),
                    vy = 0.22 + Random.nextDouble(0.0, 0.34),
                    r = 0.012 + Random.nextDouble(0.0, 0.03),
                    w = Random.nextDouble(0.0, 7.0),
                    life = 1.2 + Random.nextDouble(0.0, 1.4),
                ),
            )
        }
        val over = drops.size - 40
        if (over > 0) repeat(over) { drops.removeAt(0) }
        energy = min(1.2, energy + 0.5)
    }

    /**
     * True once the liquid has effectively stopped moving — lets a paused clock stand down under
     * reduce-motion (parity with iOS; not currently consulted by the renderer but kept for fidelity).
     */
    val settled: Boolean
        get() = abs(av) < 0.01 && abs(abv) < 0.01 && abs(target - level) < 0.001 && energy < 0.03

    companion object {
        /**
         * A non-animating sim posed at its fill line, surface flat and still — for the small gauges/tubes
         * that render ONCE (no clock → the Canvas layer is cached, zero per-frame cost). Same static-raster
         * principle as LiquidSkyStatic; only the hero vessels + HR thread actually slosh.
         */
        fun posed(target: Double): LiquidSim {
            val s = LiquidSim(target, reduceMotion = true)
            val t = target.coerceIn(0.0, 1.0)
            s.level = t; s.target = t
            s.a = 0.0; s.av = 0.0; s.ab = 0.0; s.abv = 0.0
            s.energy = 0.0
            return s
        }
    }
}

// MARK: - Shared wave sampler (ported from LiquidCore.swift)

/**
 * The surface height at horizontal position `x` (points, centred), including the two travelling
 * sines, the wall-curl (saturated at the chord), and the meniscus.
 */
fun liquidWave(
    x: Double,
    amp: Double,
    R: Double,
    hw: Double,
    curl: Double,
    ph1: Double,
    ph2: Double,
    ampMul: Double,
): Double {
    val k1 = (PI * 2) / (R * 1.5)
    val k2 = (PI * 2) / (R * 0.95)
    val xs = if (x > hw) hw else if (x < -hw) -hw else x
    var y = amp * ampMul * sin(x * k1 + ph1) + amp * ampMul * 0.6 * sin(x * k2 - ph2)
    y += curl * xs * xs * xs / (hw * hw)
    y += -0.01 * R * (abs(xs) / hw).pow(4)   // meniscus (wets the wall, just)
    return y
}

fun liquidChordHW(R: Double, sy: Double): Double =
    max(R * 0.3, if (R * R - sy * sy > 0) sqrt(R * R - sy * sy) else R * 0.3)

fun liquidCurl(av: Double): Double = max(-0.18, min(0.18, -av * 0.12))
