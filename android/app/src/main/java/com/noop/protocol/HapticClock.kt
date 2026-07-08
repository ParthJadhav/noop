package com.noop.protocol

/**
 * Haptic Clock (#460): turn a wall-clock time into a deterministic list of wrist buzzes so a user can
 * read the time off the strap without looking at a screen — a long pulse counts tens, a short pulse
 * counts units, in the order hour-tens, hour-units, minute-tens, minute-units.
 *
 * This is a PURE, platform-agnostic encoder: time-in, pulse-list-out, no I/O and no BLE. The trigger
 * ([com.noop.ble.WhoopBleClient.buzzTimeNow]) walks the list and fires each pulse through the EXISTING
 * maverick notification buzz; only the *schedule* of buzzes is new, the buzz itself is the
 * hardware-confirmed one. Kotlin twin of the Apple `HapticClock.swift`; the two pulse lists are pinned
 * identical by matching unit tests on both platforms (e.g. 3:25 → the same list).
 *
 * Reading the buzzes:
 *  - LONG pulse  = one "ten"   in the current digit group
 *  - SHORT pulse = one "unit"  in the current digit group
 *  - a short gap separates pulses; a long gap separates the four digit groups (HH-tens, HH-units,
 *    MM-tens, MM-units); an extra-long gap separates the hour block from the minute block.
 *  - a digit of 0 emits NO pulse — the group is signalled only by the surrounding group gaps.
 */
object HapticClock {

    /** One buzz instruction: buzz the wrist for [durationMs], then stay silent for [gapMs]. */
    data class Pulse(val durationMs: Int, val gapMs: Int) {
        /** Whether this is a "tens" pulse (long buzz) versus a "units" pulse (short). Swift twin:
         *  `Pulse.isLong`. Lets the trigger weight the buzz without knowing the timing table. */
        val isLong: Boolean get() = durationMs >= LONG_MS
    }

    // Pulse + gap timing (ms). Kept in lock-step with HapticClock.swift — change both together.
    // #981: the buzz itself is a fixed hardware pattern, so durationMs+gapMs is only the start-to-start
    // SPACING between buzzes. The old 250ms intra-gap left near-zero silence between unit taps, so they
    // blended on the wrist and were "almost impossible to distinguish". Widened gaps (intra-gap most of
    // all) give clear silence between taps and between digit groups while keeping the sequence practical.
    const val LONG_MS = 550        // a "tens" pulse
    const val SHORT_MS = 200       // a "units" pulse
    const val INTRA_GAP_MS = 450   // silence between two pulses inside one digit group
    const val GROUP_GAP_MS = 900   // silence between adjacent digit groups
    const val BLOCK_GAP_MS = 1500  // silence between the hour block and the minute block

    /**
     * Encode [hour]:[minute] into the buzz schedule.
     *
     * @param hour hour of day, 0..23 (24-hour input — the app already stores wall time this way).
     * @param minute minute of hour, 0..59.
     * @param is24h if `false`, the hour is mapped to 12-hour clock form (12,1..11) before encoding so
     *   the wrist count matches a 12-hour face. AM/PM is NOT signalled; only the dial reading is buzzed.
     * @return the ordered pulse list. Empty only for the degenerate all-zero 24h midnight 0:00, which
     *   has no pulses to emit; callers should treat an empty list as "nothing to buzz".
     */
    fun pulses(hour: Int, minute: Int, is24h: Boolean): List<Pulse> {
        // Clamp defensively rather than throw — this can be driven from a stored pref or a strap tap.
        val h24 = hour.coerceIn(0, 23)
        val m = minute.coerceIn(0, 59)
        val displayHour = if (is24h) h24 else twelveHour(h24)

        val hourTens = displayHour / 10
        val hourUnits = displayHour % 10
        val minTens = m / 10
        val minUnits = m % 10

        val out = ArrayList<Pulse>()

        // Hour block: tens group, then units group.
        appendGroup(out, hourTens, LONG_MS)
        closeGroup(out, GROUP_GAP_MS)
        appendGroup(out, hourUnits, SHORT_MS)
        // Separate hour block from minute block with the longer block gap.
        closeGroup(out, BLOCK_GAP_MS)

        // Minute block: tens group, then units group.
        appendGroup(out, minTens, LONG_MS)
        closeGroup(out, GROUP_GAP_MS)
        appendGroup(out, minUnits, SHORT_MS)

        // The final pulse needs no trailing gap — trim it so the sequence ends on a buzz.
        if (out.isNotEmpty()) {
            val last = out[out.size - 1]
            out[out.size - 1] = last.copy(gapMs = 0)
        }
        return out
    }

    /** 24-hour hour → 12-hour dial reading (0→12, 13→1 … 23→11). Noon stays 12. */
    fun twelveHour(h24: Int): Int {
        val h = h24 % 12
        return if (h == 0) 12 else h
    }

    /** Append [count] identical pulses (each duration [durationMs]) separated by the intra-group gap. */
    private fun appendGroup(out: MutableList<Pulse>, count: Int, durationMs: Int) {
        if (count <= 0) return
        repeat(count) { out.add(Pulse(durationMs, INTRA_GAP_MS)) }
    }

    /**
     * Widen the trailing pulse's gap to at least [gapMs] (a group/block separator). If nothing has been
     * emitted yet (a leading zero digit group, e.g. minute-tens of 0), there is no pulse to widen — the
     * missing pulse is itself the "0", and the surrounding gaps still bound the groups, so this is a
     * no-op. We take the MAX rather than overwrite so that when later groups are empty (e.g. 12:00 has
     * no minute pulses) an earlier, wider block separator isn't clobbered by a narrower group separator
     * that follows it on the same trailing pulse.
     */
    private fun closeGroup(out: MutableList<Pulse>, gapMs: Int) {
        if (out.isEmpty()) return
        val last = out[out.size - 1]
        out[out.size - 1] = last.copy(gapMs = maxOf(last.gapMs, gapMs))
    }
}
