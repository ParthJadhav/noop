package com.noop.analytics

/*
 * Spo2ReTrace.kt - the Connection-mode SpO2 reverse-engineering dump (PR #945, reimplemented). Kotlin
 * twin of the Swift Spo2ReTrace; the emitted line is byte-identical on both platforms.
 *
 * WHOOP 4.0 has the Blood O2 sensor and the historical decode already maps the raw red/IR PPG channels
 * (spo2_red@68 / spo2_ir@70 on the v24 layout), but NOOP nulls spo2Pct for WHOOP on purpose: computing a
 * calibrated % from the raw ADC needs the dense dual-wavelength waveform plus WHOOP's proprietary
 * calibration curve, and guessing it would manufacture a plausible-but-wrong health number - the exact
 * trap that withdrew the #194 PPG->HR attempt. The ONLY honest path to a reliable value is to find out
 * whether the strap already BANKS a computed SpO2 in a record field we have not mapped.
 *
 * So this dumps a handful of FULL historical records (hex) alongside their mapped SpO2 channels, log-only
 * and gated behind the Test Centre Connection mode, so an offline pass can correlate a byte (or the
 * red/IR pair) against the SpO2 % the WHOOP app shows for the same nights. Records dump whether or not
 * they carry SpO2 channels, so "the strap banks nothing" is provable too - in which case the honest
 * outcome is a capability label, never a fabricated number. NO user-facing SpO2 value comes from this.
 *
 * Pure formatter: no IO, no state, no em-dashes, no PII (a record is sensor payload; the serial never
 * rides in it).
 */
object Spo2ReTrace {

    /** Max records dumped per offload session. A handful is enough for an offline correlation pass and
     *  keeps the strap log bounded; the Backfiller counter spans chunks and resets per session. */
    const val MAX_SAMPLES = 8

    /**
     * One record's RE line: the mapped SpO2 channels + timestamp + layout version, then the FULL frame
     * hex (no prefix cap - a v24 record is ~84 B and the unmapped tail is exactly where a banked SpO2
     * would sit). Absent channels render "null" so a channel-less record still proves what it lacks.
     * Takes already-extracted ints (ConnectionTrace's primitive style, matching the Swift signature);
     * the caller reads them off its decoded record map.
     */
    fun recordLine(frame: ByteArray, version: Int?, unix: Int?, red: Int?, ir: Int?, skinRaw: Int?): String {
        val hex = frame.joinToString("") { String.format("%02x", it.toInt() and 0xFF) }
        fun f(v: Int?): String = v?.toString() ?: "null"
        return "spo2re v=${f(version)} unix=${f(unix)} red=${f(red)} ir=${f(ir)} " +
            "skinRaw=${f(skinRaw)} len=${frame.size} raw=$hex"
    }
}
