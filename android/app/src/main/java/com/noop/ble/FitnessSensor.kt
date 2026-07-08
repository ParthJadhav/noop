package com.noop.ble

/**
 * Standard fitness-sensor (RSC / CSC / CPS) pure decoders + the cumulative-counter rate computer.
 *
 * Faithful Kotlin twin of WhoopProtocol/FitnessSensorDecode.swift. Spec-deterministic field parsing for
 * the three Bluetooth SIG fitness-sensor profiles a connected accessory exposes ALONGSIDE Heart Rate
 * (0x180D) — a running footpod, a bike speed/cadence sensor, or a crank/hub power meter:
 *   - Running Speed and Cadence (RSC)  service 0x1814  measurement 0x2A53
 *   - Cycling Speed and Cadence (CSC)  service 0x1816  measurement 0x2A5B
 *   - Cycling Power (CPS)              service 0x1818  measurement 0x2A63
 *
 * Each measurement begins with a flags field whose bits gate which fields follow in a FIXED spec order.
 * We decode the fields NOOP surfaces in a live workout (speed, cadence, power, and the cumulative
 * revolution counters CSC/CPS report) and IGNORE the rest by advancing the cursor by their spec width.
 *
 * HONEST DATA: RSC carries instantaneous speed + cadence directly. CSC/CPS report CUMULATIVE counts plus
 * the time of the last event; an instantaneous speed/cadence is DERIVED from the difference between two
 * successive packets. [FitnessRateComputer] does that; a first packet yields null rather than a
 * fabricated number. CPS instantaneous power IS a direct field.
 *
 * SECURITY / ROBUSTNESS: the byte buffer is UNTRUSTED BLE input. Every read is bounds-checked; a
 * truncated/malformed packet yields the fields decoded so far (never a crash, never a read past the end)
 * — the same bounds discipline as [FitnessMachine] and [StandardHeartRate].
 *
 * Pure (no android.bluetooth) → unit-tested on the JVM against spec byte fixtures, like FitnessMachine.
 *
 * Reference: Bluetooth SIG RSC 1.0, CSC 1.0, CPS 1.1 + the GATT Specification Supplement field tables.
 * NOOP's own clean re-implementation of the public spec (no GPL/AGPL source consulted — facts only).
 */
object FitnessSensor {

    /** Which standard fitness-sensor measurement produced a reading. */
    enum class SensorKind(val uuid16: String, val displayName: String) {
        RUNNING_SPEED_CADENCE("2A53", "Running Sensor"),
        CYCLING_SPEED_CADENCE("2A5B", "Cycling Sensor"),
        CYCLING_POWER("2A63", "Power Meter"),
    }

    /**
     * A single decoded fitness-sensor measurement. Every field is nullable — a sensor advertises only a
     * subset, and a truncated packet decodes only what fit. For CSC/CPS the cumulative counters + event
     * times are the RAW spec fields; [FitnessRateComputer] turns successive readings into instantaneous
     * speed/cadence. RSC reports speed/cadence directly; CPS reports power directly.
     */
    data class Reading(
        val kind: SensorKind,
        // RSC direct fields
        val speedMps: Double? = null,
        val runningCadenceSpm: Int? = null,
        val isRunning: Boolean? = null,
        val totalDistanceM: Double? = null,
        // CPS direct field
        val instantaneousPowerWatts: Int? = null,
        // CSC / CPS cumulative fields (feed the rate computer)
        val cumulativeWheelRevolutions: Long? = null,   // u32
        // Wheel event time (u16, wraps at 65536). UNIT IS SOURCE-DEPENDENT: 1/1024 s from CSC (0x2A5B)
        // but 1/2048 s from CPS (0x2A63) — Cycling Power Service 1.1, Wheel Revolution Data.
        // [FitnessRateComputer] branches on [kind]; the field name keeps the CSC unit for Kotlin↔Swift
        // parity with the shipped schema rather than churning every call-site (PR #1007).
        val lastWheelEventTime1024: Int? = null,
        val cumulativeCrankRevolutions: Int? = null,     // u16
        val lastCrankEventTime1024: Int? = null,
    ) {
        /** Speed in km/h, if this reading carries a direct instantaneous speed (RSC); null otherwise. */
        val speedKmh: Double? get() = speedMps?.let { it * 3.6 }
    }

    /** A forward cursor over the byte buffer; reads advance only on success (bounds-checked). */
    private class Reader(val bytes: ByteArray) {
        var idx = 0
        fun u8(): Int? {
            if (idx >= bytes.size) return null
            return (bytes[idx++].toInt() and 0xFF)
        }
        fun u16(): Int? {
            if (idx + 1 >= bytes.size) return null
            val v = (bytes[idx].toInt() and 0xFF) or ((bytes[idx + 1].toInt() and 0xFF) shl 8)
            idx += 2
            return v
        }
        /** Signed 16-bit (two's complement) — CPS instantaneous power is sint16. */
        fun s16(): Int? {
            val raw = u16() ?: return null
            return if (raw >= 0x8000) raw - 0x10000 else raw
        }
        fun u24(): Int? {
            if (idx + 2 >= bytes.size) return null
            val v = (bytes[idx].toInt() and 0xFF) or
                ((bytes[idx + 1].toInt() and 0xFF) shl 8) or
                ((bytes[idx + 2].toInt() and 0xFF) shl 16)
            idx += 3
            return v
        }
        fun u32(): Long? {
            if (idx + 3 >= bytes.size) return null
            val v = (bytes[idx].toLong() and 0xFF) or
                ((bytes[idx + 1].toLong() and 0xFF) shl 8) or
                ((bytes[idx + 2].toLong() and 0xFF) shl 16) or
                ((bytes[idx + 3].toLong() and 0xFF) shl 24)
            idx += 4
            return v
        }
        fun skip(n: Int) { idx = minOf(bytes.size, idx + n) }
    }

    // MARK: - Running Speed and Cadence (0x2A53)
    fun runningSpeedCadence(data: ByteArray): Reading? {
        val r = Reader(data)
        val flags = r.u8() ?: return null
        var speed: Double? = null
        var cadence: Int? = null
        var distance: Double? = null

        r.u16()?.let { speed = it / 256.0 }          // 1/256 m/s (mandatory)
        r.u8()?.let { cadence = it }                 // steps/min (mandatory)
        if (flags and 0x01 != 0) r.u16()             // Instantaneous Stride Length (skip)
        if (flags and 0x02 != 0) r.u32()?.let { distance = it / 10.0 } // Total Distance (1/10 m)
        return Reading(
            SensorKind.RUNNING_SPEED_CADENCE,
            speedMps = speed,
            runningCadenceSpm = cadence,
            isRunning = (flags and 0x04 != 0),
            totalDistanceM = distance,
        )
    }

    // MARK: - Cycling Speed and Cadence (0x2A5B)
    fun cyclingSpeedCadence(data: ByteArray): Reading? {
        val r = Reader(data)
        val flags = r.u8() ?: return null
        var wheelRevs: Long? = null
        var wheelTime: Int? = null
        var crankRevs: Int? = null
        var crankTime: Int? = null

        if (flags and 0x01 != 0) {                   // Wheel Revolution Data
            r.u32()?.let { wheelRevs = it }
            r.u16()?.let { wheelTime = it }
        }
        if (flags and 0x02 != 0) {                   // Crank Revolution Data
            r.u16()?.let { crankRevs = it }
            r.u16()?.let { crankTime = it }
        }
        return Reading(
            SensorKind.CYCLING_SPEED_CADENCE,
            cumulativeWheelRevolutions = wheelRevs,
            lastWheelEventTime1024 = wheelTime,
            cumulativeCrankRevolutions = crankRevs,
            lastCrankEventTime1024 = crankTime,
        )
    }

    // MARK: - Cycling Power Measurement (0x2A63)
    fun cyclingPower(data: ByteArray): Reading? {
        val r = Reader(data)
        val flags = r.u16() ?: return null
        var power: Int? = null
        var wheelRevs: Long? = null
        var wheelTime: Int? = null
        var crankRevs: Int? = null
        var crankTime: Int? = null

        r.s16()?.let { power = it }                  // Instantaneous Power (mandatory)
        if (flags and 0x0001 != 0) r.u8()            // Pedal Power Balance
        if (flags and 0x0004 != 0) r.u16()           // Accumulated Torque
        if (flags and 0x0010 != 0) {                 // Wheel Revolution Data (event time 1/2048 s here,
            r.u32()?.let { wheelRevs = it }          //  unlike CSC's 1/1024 — see Reading doc, PR #1007)
            r.u16()?.let { wheelTime = it }
        }
        if (flags and 0x0020 != 0) {                 // Crank Revolution Data
            r.u16()?.let { crankRevs = it }
            r.u16()?.let { crankTime = it }
        }
        if (flags and 0x0040 != 0) r.skip(4)         // Extreme Force Magnitudes
        if (flags and 0x0080 != 0) r.skip(4)         // Extreme Torque Magnitudes
        if (flags and 0x0100 != 0) r.u24()           // Extreme Angles
        if (flags and 0x0200 != 0) r.u16()           // Top Dead Spot Angle
        if (flags and 0x0400 != 0) r.u16()           // Bottom Dead Spot Angle
        if (flags and 0x0800 != 0) r.u16()           // Accumulated Energy
        return Reading(
            SensorKind.CYCLING_POWER,
            instantaneousPowerWatts = power,
            cumulativeWheelRevolutions = wheelRevs,
            lastWheelEventTime1024 = wheelTime,
            cumulativeCrankRevolutions = crankRevs,
            lastCrankEventTime1024 = crankTime,
        )
    }

    /** Decode by the 16-bit characteristic UUID short form (case-insensitive); null for unknown/empty. */
    fun decode(uuid16: String, data: ByteArray): Reading? = when (uuid16.uppercase()) {
        "2A53" -> runningSpeedCadence(data)
        "2A5B" -> cyclingSpeedCadence(data)
        "2A63" -> cyclingPower(data)
        else -> null
    }
}

/**
 * Turns successive CSC/CPS revolution counters into instantaneous wheel speed and crank/pedal cadence.
 *
 * HONEST DERIVATION: CSC/CPS report only CUMULATIVE counts + the event time of the last revolution (u16,
 * wrapping at 65536). An instantaneous rate is the count difference over the time difference between two
 * packets — so the FIRST packet, and any packet that repeats the same event time, yield null, never a
 * fabricated value. Time wrap and counter wrap (u32 wheel / u16 crank) are handled with modular
 * arithmetic. Pure — no I/O — so it's fully unit-tested.
 *
 * TICK RATES (PR #1007): the wheel event-time clock is SOURCE-dependent — CSC (0x2A5B) ticks at 1/1024 s
 * but CPS (0x2A63) at 1/2048 s (Cycling Power Service 1.1, Wheel Revolution Data). A shared 1024 divisor
 * made a CPS wheel delta look twice as long as reality, HALVING CPS-derived speed. The wheel path
 * therefore selects the rate from [FitnessSensor.Reading.kind] — and because a 2A5B↔2A63 flip means the
 * baseline timestamp sits on a DIFFERENT clock base, a kind flip drops the wheel baseline so the first
 * post-flip packet yields null rather than a speed computed across mixed clocks. Crank event time is
 * 1/1024 s on BOTH profiles, so the crank path is unchanged.
 *
 * Faithful twin of Swift `FitnessRateComputer`.
 */
class FitnessRateComputer(
    /** Wheel circumference in metres (spec default road 700×25c tyre ≈ 2.105 m). Speed is only as honest
     *  as this number, so it's surfaced as an estimate. */
    var wheelCircumferenceM: Double = 2.105,
) {
    private var lastWheelRevs: Long? = null
    private var lastWheelTime: Int? = null
    /** Which profile the wheel baseline came from. CSC and CPS wheel event times tick on DIFFERENT clock
     *  bases (1/1024 vs 1/2048 s), so a delta across a kind flip is meaningless — the baseline is dropped
     *  when the kind changes and the first post-flip packet re-seeds it (PR #1007). */
    private var lastWheelKind: FitnessSensor.SensorKind? = null
    private var lastCrankRevs: Int? = null
    private var lastCrankTime: Int? = null

    /** A computed result; any field is null when it couldn't be derived (first packet, no new rev, or the
     *  relevant data block was absent). */
    data class Rates(val speedMps: Double? = null, val crankRpm: Double? = null) {
        val speedKmh: Double? get() = speedMps?.let { it * 3.6 }
    }

    /** Fold one decoded reading in and return whatever instantaneous rates it lets us derive. Remembers
     *  this packet's counters as the baseline for the next. The wheel path additionally tracks WHICH
     *  profile the baseline came from, because CSC and CPS wheel timestamps are not on the same clock
     *  base (see the class doc, PR #1007). */
    fun update(reading: FitnessSensor.Reading): Rates {
        var speed: Double? = null
        var crankRpm: Double? = null

        val wheelRevs = reading.cumulativeWheelRevolutions
        val wheelTime = reading.lastWheelEventTime1024
        if (wheelRevs != null && wheelTime != null) {
            // PR #1007: the wheel event-time tick rate is profile-specific — CSC (0x2A5B) 1/1024 s,
            // CPS (0x2A63) 1/2048 s. A shared /1024 halved CPS-derived speed. The 16-bit wrap in
            // timeDelta1024 is tick-count arithmetic, so only the seconds conversion branches.
            val wheelTicksPerSec =
                if (reading.kind == FitnessSensor.SensorKind.CYCLING_POWER) 2048.0 else 1024.0
            // A 2A5B↔2A63 kind flip puts the baseline timestamp on a DIFFERENT clock base; a cross-base
            // delta would fabricate a speed, so drop the baseline and let this packet re-seed it (the
            // first post-flip packet yields null — same honesty rule as a true first packet).
            if (lastWheelKind != reading.kind) {
                lastWheelRevs = null
                lastWheelTime = null
            }
            val pRevs = lastWheelRevs
            val pTime = lastWheelTime
            if (pRevs != null && pTime != null) {
                val dt = timeDelta1024(wheelTime, pTime)
                if (dt > 0) {
                    // u32 counter wrap handled with a 2^32 modulus.
                    val dRev = ((wheelRevs - pRevs) % 0x1_0000_0000L + 0x1_0000_0000L) % 0x1_0000_0000L
                    val seconds = dt / wheelTicksPerSec
                    speed = dRev * wheelCircumferenceM / seconds
                }
            }
            lastWheelRevs = wheelRevs
            lastWheelTime = wheelTime
            lastWheelKind = reading.kind
        }

        val crankRevs = reading.cumulativeCrankRevolutions
        val crankTime = reading.lastCrankEventTime1024
        if (crankRevs != null && crankTime != null) {
            val pRevs = lastCrankRevs
            val pTime = lastCrankTime
            if (pRevs != null && pTime != null) {
                val dt = timeDelta1024(crankTime, pTime)
                if (dt > 0) {
                    val dRev = ((crankRevs - pRevs) % 65536 + 65536) % 65536   // u16 counter wrap
                    val minutes = (dt / 1024.0) / 60.0
                    crankRpm = dRev / minutes
                }
            }
            lastCrankRevs = crankRevs
            lastCrankTime = crankTime
        }

        return Rates(speedMps = speed, crankRpm = crankRpm)
    }

    /** Forget the baselines (call on disconnect / new session). */
    fun reset() {
        lastWheelRevs = null; lastWheelTime = null; lastWheelKind = null
        lastCrankRevs = null; lastCrankTime = null
    }

    companion object {
        /** Modular difference of two 1/1024-s event-time stamps, accounting for the 16-bit wrap at 65536.
         *  Returns elapsed ticks in [0, 65536). 0 means no time has passed (same event) → no rate. */
        private fun timeDelta1024(now: Int, prev: Int): Int = ((now - prev) % 65536 + 65536) % 65536
    }
}
