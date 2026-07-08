package com.noop.oura

// RingGen: per-generation capability + command-set selection. Kotlin twin of OuraRingGen.swift. One
// transport handles all gens by swapping command sets, not code paths. The framing/auth/event-tag
// dictionary are generation-invariant (per OURA_PROTOCOL.md s7.2), so RingGen only drives:
//   - MTU clamp (203 vs 247)
//   - which characteristics to discover (gen5 extra notify chars, currently unused)
//   - the live-HR enable command set (verified on gen3, expected-same on gen4/5)
//   - the registered capability set surfaced to the app
//
// Platform-pure value type. Facts cited per OURA_PROTOCOL.md s7.

enum class OuraRingGen(val raw: String) {
    GEN3("gen3"),
    GEN4("gen4"),
    GEN5("gen5");

    /**
     * Human-facing model name carried on the paired device's model (no schema change). The app
     * recovers the generation via from(model:). Per architecture plan s5.
     */
    val displayName: String
        get() = when (this) {
            GEN3 -> "Oura Ring 3"
            GEN4 -> "Oura Ring 4"
            GEN5 -> "Oura Ring 5"
        }

    /** Negotiated ATT MTU for this generation. Per OURA_PROTOCOL.md s1.2. */
    val mtu: Int
        get() = when (this) {
            GEN3 -> OuraGatt.mtuGen3
            GEN4, GEN5 -> OuraGatt.mtuGen45
        }

    /** Max writable payload after the 3-byte ATT overhead. Per OURA_PROTOCOL.md s1.3. */
    val maxWritePayload: Int get() = mtu - OuraGatt.attOverhead

    /**
     * Whether this generation advertises the extra ...0004/5/6 characteristics. Only gen5 does, and
     * v1 never writes to them (roles unconfirmed). Per OURA_PROTOCOL.md s1.2 / s7.2.
     */
    val hasExtraNotifyChars: Boolean
        get() = when (this) {
            GEN3, GEN4 -> false
            GEN5 -> true
        }

    /**
     * The numeric generation marker. The feature-mode master gate requires generation > 2 (gen3+);
     * gen <= 2 reject all feature-mode changes. All three supported gens satisfy this.
     * Per OURA_PROTOCOL.md s7.1.
     */
    val generationNumber: Int
        get() = when (this) {
            GEN3 -> 3
            GEN4 -> 4
            GEN5 -> 5
        }

    /**
     * True when this generation accepts feature-mode writes (live-HR / SpO2 enable). All supported
     * generations are gen3+, so always true here; kept explicit for the s7.1 master-gate rule.
     */
    val supportsFeatureMode: Boolean get() = generationNumber > 2

    /**
     * Metrics this generation can register. Gen3+ all expose the same event-tag dictionary, so the
     * capability set is currently uniform; kept per-gen so a future gen-specific gate is a one-line
     * change. Per OURA_PROTOCOL.md s7.2.
     */
    val capabilities: Set<OuraMetric>
        get() = when (this) {
            GEN3, GEN4, GEN5 ->
                setOf(OuraMetric.HR, OuraMetric.HRV, OuraMetric.SPO2, OuraMetric.SKIN_TEMP, OuraMetric.SLEEP)
        }

    companion object {
        /**
         * Best-effort generation guess from an advertised peripheral name. Oura does not reliably
         * encode the generation in the BLE name, so this is a hint only; the wizard confirms via the
         * model the user picks. Returns null when nothing matches. Per architecture plan s5.
         */
        fun recognise(advertisedName: String?): OuraRingGen? {
            val name = advertisedName?.lowercase() ?: return null
            // Only treat as an Oura ring at all if the name carries the brand token.
            if (!name.contains("oura") && !name.contains("ring")) return null
            if (name.contains("5")) return GEN5
            if (name.contains("4")) return GEN4
            if (name.contains("3") || name.contains("horizon")) return GEN3
            return null
        }

        /**
         * Recover the generation from a stored model string ("Oura Ring 3/4/5"). Defaults to gen3 (the
         * verified-corpus generation) when the string is unrecognised, so an older row still maps to a
         * usable command set. Per architecture plan s5.
         */
        fun from(model: String): OuraRingGen {
            val m = model.lowercase()
            if (m.contains("5")) return GEN5
            if (m.contains("4")) return GEN4
            if (m.contains("3")) return GEN3
            return GEN3
        }
    }
}

/**
 * Capability metrics an Oura ring can register, parallel to the app-side Metric set. Kept local to
 * the protocol package so the package stays dependency-free; the app maps these onto its own Metric.
 */
enum class OuraMetric(val raw: String) {
    HR("hr"),
    HRV("hrv"),
    SPO2("spo2"),
    SKIN_TEMP("skinTemp"),
    SLEEP("sleep"),
}
