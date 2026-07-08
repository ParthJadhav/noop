package com.noop.protocol

// LiveSessionHaptics.kt — the two, and only two, wrist signals the Live Session coach sends. Pure,
// platform-agnostic: signal-in, pulse-list-out, no I/O and no BLE. Byte-for-byte mirror of
// Strand/Packages/WhoopProtocol/Sources/WhoopProtocol/LiveSessionHaptics.swift. The trigger walks the list
// and fires each pulse through the EXISTING hardware buzz, weighting by Pulse.isLong (long = heavier 2-loop,
// short = lighter 1-loop) — the same mechanism HapticClock/BreathPacer already use.
//
//   • PUSH     — two LIGHT taps  → "give a bit more"
//   • EASE_OFF — three HEAVY taps → "ease off, today can't pay for this"
//
// The two pulse lists are pinned identical to the Swift twin by matching unit tests. Design contract:
// docs/superpowers/specs/2026-07-04-live-sessions-design.md.
object LiveSessionHaptics {

    /** The coach's entire signalling vocabulary. Silence is the third, most common state — it is never sent. */
    enum class Signal { PUSH, EASE_OFF }

    /** The ordered buzz list for a signal. Reuses HapticClock's pulse timing so the two features stay in step. */
    fun pulses(signal: Signal): List<HapticClock.Pulse> = when (signal) {
        Signal.PUSH -> trimmed(
            listOf(
                HapticClock.Pulse(HapticClock.SHORT_MS, HapticClock.INTRA_GAP_MS),
                HapticClock.Pulse(HapticClock.SHORT_MS, HapticClock.INTRA_GAP_MS),
            )
        )
        Signal.EASE_OFF -> trimmed(
            listOf(
                HapticClock.Pulse(HapticClock.LONG_MS, HapticClock.INTRA_GAP_MS),
                HapticClock.Pulse(HapticClock.LONG_MS, HapticClock.INTRA_GAP_MS),
                HapticClock.Pulse(HapticClock.LONG_MS, HapticClock.INTRA_GAP_MS),
            )
        )
    }

    /** The sequence ends on a buzz, not a gap — trim the final pulse's trailing gap to 0. */
    private fun trimmed(pulses: List<HapticClock.Pulse>): List<HapticClock.Pulse> {
        if (pulses.isEmpty()) return pulses
        val out = pulses.toMutableList()
        val last = out.last()
        out[out.size - 1] = HapticClock.Pulse(last.durationMs, 0)
        return out
    }
}
