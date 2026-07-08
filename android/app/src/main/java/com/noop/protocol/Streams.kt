package com.noop.protocol

/**
 * Decoded stream rows — the durable, compact local record produced from parsed frames.
 *
 * Ported from the Swift reference (Streams.swift). `ts` is wall-clock unix seconds throughout.
 * These are pure data carriers with no Android/Room dependency; the data layer maps them onto
 * Room entities (HrSample, RrInterval, EventRow, BatterySample) as needed.
 */

/** A heart-rate sample at wall-clock unix seconds [ts]. */
data class HrSample(val ts: Int, val bpm: Int)

/** A single beat-to-beat R-R interval (ms) at wall-clock unix seconds [ts]. */
data class RrInterval(val ts: Int, val rrMs: Int)

/**
 * A raw-ADC SpO2 sample at wall-clock unix seconds [ts]. Mirrors the Room `Spo2Sample` (red/ir)
 * and the Swift `SpO2Sample(red:ir:unit:)` shape so [StreamPersistence.toBatch] is a 1:1 widen.
 * Historically only the type-47 historical-offload path produced these; the live carrier now also
 * carries them so a single-value optical source (the Oura ring exposes ONE combined SpO2 reading,
 * not separate red/ir channels) can flow live. Such a source puts its raw value in [red] and
 * leaves [ir] at 0 (an unread channel, never a fabricated second reading).
 *
 * [unit] preserves the decoder's own scale tag (e.g. "raw_adc"/"raw"/"dc_raw") so a downstream
 * reader never assumes a percentage. This mirrors the unit fidelity the Swift `SpO2Sample` carries,
 * so the unit is not silently dropped on the Kotlin side at the carrier level. (The Room `Spo2Sample`
 * entity has no unit column yet; the carrier-level tag documents the convention until a migration
 * adds one.)
 */
data class Spo2Sample(val ts: Int, val red: Int, val ir: Int, val unit: String = "raw_adc")

/**
 * A skin-temperature sample at wall-clock unix seconds [ts]. Mirrors the Room `SkinTempSample` and
 * the Swift `SkinTempSample(raw:unit:)` shape.
 *
 * UNIT CONVENTION: [raw] is a device-native register value whose °C scale is FAMILY-SPECIFIC (#938) —
 * the 5/MG v18 @73 field is CENTI-degrees C (°C = raw / 100), but the WHOOP 4.0 v24 @72 field is a RAW
 * ADC on a different scale. The analytics reader (AnalyticsEngine / wornNightlySkinTempC, both platforms)
 * converts via [skinTempCelsius], which branches on [DeviceFamily]; running the 4.0 raw through /100 read
 * every worn night ~8 °C, below the 28 °C worn gate (issue #938). The live Oura path stores celsius * 100
 * (the 5/MG centidegree convention), so its raw decodes identically on Android and macOS. [unit] carries a
 * scale tag ("raw_adc") so the scale is never silently assumed. (The Room entity has no unit column yet;
 * this carrier-level tag plus this comment document the convention until a migration adds one.)
 */
data class SkinTempSample(val ts: Int, val raw: Int, val unit: String = "raw_adc")

/**
 * WHOOP 4.0 (v24) skin-temp mapping constants (#938). The single provisional slope + anchor live in ONE
 * place so the two-point-calibration TODO has an obvious home. Kept in lockstep with the Swift
 * `Whoop4SkinTemp`.
 */
object Whoop4SkinTemp {
    /** Worn resting raw register value the anchor pins (reporter's steady worn baseline, ~826). */
    const val ANCHOR_RAW: Double = 826.0

    /** Physiological nocturnal wrist skin temperature the anchor raw maps to (°C). */
    const val ANCHOR_CELSIUS: Double = 33.0

    /** PROVISIONAL °C-per-raw-unit slope. TODO(#938): replace with the two-point anchor slope. */
    const val PROVISIONAL_SLOPE_C_PER_RAW: Double = 0.05
}

/**
 * Convert a raw `skin_temp_raw` register value to °C, DEVICE-FAMILY-AWARE (#938).
 *
 * The two families bank skin temp on DIFFERENT scales, and applying one family's scale to the other is a
 * real decode bug: the historical `skin_temp_raw` field is a RAW ADC on the WHOOP 4.0 (v24 @72, "degC
 * computed server-side" per the schema) but a CENTIDEGREE register on the 5/MG (v18 @73). A single
 * family-blind `raw/100` sent every 4.0 night ~8 °C low, below the 28 °C worn gate, so skin temp and the
 * illness signal vanished (issue #938, reporter dpguglielmi's 4.0 capture).
 *
 * - [DeviceFamily.WHOOP5]: `raw / 100`. PROVEN on real 5/MG captures (Whoop5HistoricalTests: worn 3057 =
 *   30.6 °C, off-wrist 2247 = 22.5 °C). Unchanged.
 *
 * - [DeviceFamily.WHOOP4]: a single-anchor affine map. The 4.0 firmware (41.17.6.0) banks byte-72 at 1 Hz
 *   ON-WRIST ONLY, so there is ONE solid anchor and NO clean off-wrist room anchor from the strap. The
 *   reporter's doff/don capture gives a steady worn resting value of raw ~826 (worn steady ~830–865; a
 *   no-contact floor ~510–520 at removal, then banking stops). Under `/100` that reads ~8.3 °C — impossible
 *   for a wrist streaming a resting HR (~52 bpm). We anchor the worn value at a defensible nocturnal wrist
 *   skin temperature (33.0 °C ↔ raw 826) and carry a PROVISIONAL slope until a second calibration point
 *   exists. Because downstream use is a deviation from the user's OWN nightly baseline (skinTempDevC), the
 *   offset is what must be right to clear the absolute 28–42 °C worn gate + 20–42 °C baseline clamp; a slope
 *   error only rescales the deviation and stays directionally correct. All 4.0 values APPROXIMATE.
 *
 *   TODO(#938): replace the provisional slope with the exact two-point anchor once a second worn point at a
 *   markedly different ambient pins the ADC→°C transfer (including whether it is linear). Until then this is
 *   a defensible worn-range mapping, NOT a claimed-accurate absolute thermometer. Kept in lockstep with the
 *   Swift `skinTempCelsius(raw:family:)`.
 */
fun skinTempCelsius(raw: Int, family: DeviceFamily): Double = when (family) {
    DeviceFamily.WHOOP5 -> raw / 100.0
    DeviceFamily.WHOOP4 ->
        Whoop4SkinTemp.ANCHOR_CELSIUS +
            (raw - Whoop4SkinTemp.ANCHOR_RAW) * Whoop4SkinTemp.PROVISIONAL_SLOPE_C_PER_RAW
}

/**
 * A device event. [ts] is real RTC unix seconds (already wall-clock, never offset). [kind] is the
 * event label (e.g. "BATTERY_LEVEL(3)", "WRIST_OFF(10)"); [payload] carries any extra decoded
 * fields with `event`/`event_timestamp` removed.
 */
data class WhoopEvent(val ts: Int, val kind: String, val payload: Map<String, Any?>)

/**
 * A battery reading. [ts] is event RTC for BATTERY_LEVEL events, else the wall-clock reference.
 * [charging] is a real Boolean only when the frame reported it (BATTERY_LEVEL events); `null`
 * otherwise (command responses).
 */
data class BatterySample(
    val ts: Int,
    val soc: Double?,
    val mv: Int?,
    val charging: Boolean? = null,
)

/** The bundle of decoded series extracted from a batch of parsed frames. */
data class Streams(
    val hr: MutableList<HrSample> = mutableListOf(),
    val rr: MutableList<RrInterval> = mutableListOf(),
    val events: MutableList<WhoopEvent> = mutableListOf(),
    val battery: MutableList<BatterySample> = mutableListOf(),
    // spo2/skinTemp default empty so every existing WHOOP-path constructor/extractStreams call site is
    // unchanged; only a source that decodes these biometric signals live (the Oura ring) populates them.
    val spo2: MutableList<Spo2Sample> = mutableListOf(),
    val skinTemp: MutableList<SkinTempSample> = mutableListOf(),
) {
    companion object {
        val EMPTY: Streams get() = Streams()
    }
}

/**
 * Map a device-epoch timestamp to wall-clock unix seconds via a pure linear offset.
 * Assumes strap clock and wall clock tick at the same rate (no skew/drift). Port of `_to_wall`.
 */
private fun toWall(deviceTs: Int?, deviceClockRef: Int, wallClockRef: Int): Int? {
    if (deviceTs == null) return null
    return wallClockRef + (deviceTs - deviceClockRef)
}

/**
 * Turn parsed frames into datastore rows. Port of `interpreter.extract_streams`.
 *
 * HR/R-R are taken ONLY from REALTIME_DATA (type 40). REALTIME_RAW_DATA (type 43) also carries an
 * HR byte but streams alongside type-40 during raw collection, so routing both would double-count
 * HR for the same instants. CRC-failed and non-ok frames are skipped.
 */
fun extractStreams(parsed: List<ParsedFrame>, deviceClockRef: Int, wallClockRef: Int): Streams {
    val out = Streams()
    for (r in parsed) {
        if (!r.ok || r.crcOk == false) continue
        val p = r.parsed
        when (r.typeName) {
            "REALTIME_DATA" -> {
                val ts = toWall(p.intOrNull("timestamp"), deviceClockRef, wallClockRef)
                if (ts != null) {
                    p.intOrNull("heart_rate")?.let { bpm -> out.hr.add(HrSample(ts, bpm)) }
                    // Drop RR rows when timestamp is absent (a ts-less RR row is unstorable).
                    p.intArrayOrNull("rr_intervals")?.let { rrs ->
                        for (rr in rrs) out.rr.add(RrInterval(ts, rr))
                    }
                }
            }

            "EVENT" -> {
                // EVENT timestamps are real RTC unix seconds — already wall-clock, NOT offset.
                val ts = p.intOrNull("event_timestamp") ?: continue
                val kind = p.stringOrNull("event") ?: ""
                // BATTERY_LEVEL events (~every 8 min) carry SoC/mV/charging → the DENSE series.
                if (kind.startsWith("BATTERY_LEVEL")) appendBattery(out, ts, p)
                val payload = p.toMutableMap()
                payload.remove("event")
                payload.remove("event_timestamp")
                out.events.add(WhoopEvent(ts, kind, payload))
            }

            "COMMAND_RESPONSE" -> {
                // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
                appendBattery(out, wallClockRef, p)
            }

            else -> Unit
        }
    }
    return out
}

/**
 * Append a [BatterySample] from a parsed frame's `battery_pct`/`battery_mV`/`battery_charging`
 * fields (no-op when neither soc nor mv is present). `charging` is a real Boolean only when the
 * frame reported it (BATTERY_LEVEL events); command responses leave it null.
 */
internal fun appendBattery(out: Streams, ts: Int, p: Map<String, Any?>) {
    val soc = p.doubleOrNull("battery_pct")
    val mv = p.intOrNull("battery_mV")
    if (soc == null && mv == null) return
    val charging = p.intOrNull("battery_charging")?.let { it != 0 }
    out.battery.add(BatterySample(ts = ts, soc = soc, mv = mv, charging = charging))
}

// MARK: - Heterogeneous parsed-map accessors (mirror Swift's ParsedValue.intValue/etc.)

internal fun Map<String, Any?>.intOrNull(key: String): Int? = when (val v = this[key]) {
    is Int -> v
    is Long -> v.toInt()
    else -> null
}

internal fun Map<String, Any?>.doubleOrNull(key: String): Double? = when (val v = this[key]) {
    is Double -> v
    is Int -> v.toDouble()
    is Long -> v.toDouble()
    else -> null
}

internal fun Map<String, Any?>.stringOrNull(key: String): String? = this[key] as? String

@Suppress("UNCHECKED_CAST")
internal fun Map<String, Any?>.intArrayOrNull(key: String): List<Int>? = this[key] as? List<Int>
