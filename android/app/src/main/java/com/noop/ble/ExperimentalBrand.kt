package com.noop.ble

import java.text.Normalizer

/**
 * CLEAN-ROOM best-effort recognition of the EXPERIMENTAL band families from an advertised device name.
 *
 * Faithful Kotlin twin of Strand/BLE/ExperimentalBrand.swift. Pure (no android.bluetooth) so it's
 * JVM-unit-tested. Deliberately conservative: an unrecognised name returns null rather than a wrong
 * guess. NOTHING here fabricates data — it only labels a discovered peripheral so the experimental
 * add-device flow can show the honest per-brand guidance. Recognition is by advertised-name substring
 * only (the cheapest, most reliable public signal). US English throughout.
 */
enum class ExperimentalBrand(val displayBrand: String, val canStreamLiveHR: Boolean) {
    /** Amazfit / Zepp / Huami family (incl. Helio ring/band). Best-effort live HR: standard 0x180D where
     *  exposed, else the documented Huami custom HR characteristic. */
    AMAZFIT("Amazfit", true),
    /** Xiaomi Mi Band (Huami-family). Older bands expose HR on a custom char; newer need an auth handshake
     *  we can't do — the driver surfaces that honestly rather than faking it. */
    MI_BAND("Mi Band", true),
    /** Garmin watch. Live HR is the STANDARD broadcast-HR path (0x180D) when the user enables
     *  "Broadcast Heart Rate" — there is no NOOP-proprietary Garmin protocol. */
    GARMIN("Garmin", true),
    /** Oura ring. No open live health stream — proprietary, syncs to Oura's app. The driver makes the
     *  detection attempt, then points honestly at file import. */
    OURA("Oura", false);

    companion object {
        /** Best-effort brand from an advertised name. Returns null for an unrecognised name (no wrong guess). */
        fun recognise(name: String): ExperimentalBrand? {
            // Fold diacritics before matching so Garmin's accented branding (e.g. "vívoactive", "fēnix")
            // is recognised the same as its ASCII advertised form. Mirrors Swift's
            // `folding(options: .diacriticInsensitive)`. A device can advertise either form.
            val n = Normalizer.normalize(name, Normalizer.Form.NFD)
                .replace(Regex("\\p{M}+"), "")
                .lowercase()
            // Order matters: most specific tokens first. Mi Band is a Huami sub-brand, so test its tokens
            // before Amazfit's.
            if (n.contains("mi band") || n.contains("miband") || n.contains("smart band") || n.contains("xiaomi")) {
                return MI_BAND
            }
            if (n.contains("amazfit") || n.contains("zepp") || n.contains("helio") || n.contains("huami")) {
                return AMAZFIT
            }
            if (n.contains("garmin") || n.contains("forerunner") || n.contains("fenix") ||
                n.contains("vivoactive") || n.contains("venu") || n.contains("instinct") ||
                n.contains("epix") || n.contains("vivosmart")
            ) {
                return GARMIN
            }
            if (n.contains("oura")) return OURA
            return null
        }
    }
}
