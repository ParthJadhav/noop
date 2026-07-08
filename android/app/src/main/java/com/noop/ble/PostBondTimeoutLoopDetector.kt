package com.noop.ble

/**
 * Mirror of the Swift `PostBondTimeoutLoopDetector` (Strand/BLE/BLEManager.swift).
 *
 * Detects a WHOOP 4 "bond-loop" (#617): the strap bonds successfully, then the encrypted link drops
 * ~1s later with a CONNECTION TIMEOUT (Android `GATT_CONN_TIMEOUT` / `0x08`, the twin of iOS
 * `CBError.connectionTimeout`), the auto-rescan reconnects, it bonds again, and dies again — an
 * endless bond->timeout cycle that never settles and never tells the user why.
 *
 * The tell is a TIMEOUT drop that lands shortly after a GENUINE bond: bond -> die-soon -> rescan ->
 * bond -> die-soon. A bond that survives well past the window is healthy and breaks the streak — links
 * flap for benign reasons minutes in, and a late drop must NOT be blamed on the bond. We don't trip on a
 * single cycle (one quick drop is noise); we trip on >= [tripThreshold] CONSECUTIVE
 * bond-then-quick-timeout cycles. Once tripped, the client surfaces the EXISTING re-pair guide
 * (`reconnectGuide`) so the user gets the forget-and-re-pair steps instead of watching a silent loop
 * drain the battery.
 *
 * Pure value type -> unit-testable without a BLE seam — same shape as the Swift detector and
 * [EmptySyncTracker].
 */
class PostBondTimeoutLoopDetector(
    /**
     * How many consecutive bond-then-quick-timeout cycles before we surface the re-pair guide.
     * 2 (not 1): one quick post-bond drop is noise; two in a row is the loop, not a fluke.
     */
    private val tripThreshold: Int = 2,
    /**
     * A timeout only counts as "right after bonding" if it lands within this many milliseconds of the
     * bond. A drop well into a healthy session is unrelated to bonding and must NOT count (that would
     * mis-trip a good link that merely flapped later). Generous vs the radio detector's 20s: the loop's
     * signature is a near-immediate (~1s) drop, but pre-loop links can limp a few seconds before timing
     * out. 8s, matching the Swift `quickTimeoutWindow` of 8 seconds.
     */
    val quickTimeoutWindowMs: Long = 8_000L,
) {
    var consecutiveBondTimeouts = 0
        private set

    /** True once we've tripped: the client has surfaced (or should surface) the re-pair guide. */
    var tripped = false
        private set

    /**
     * A connection ended. [wasBonded] = the link reached a genuine encrypted bond this connection;
     * [msSinceBond] = how long after bonding the link ended in milliseconds (null if we never bonded);
     * [timedOut] = the drop looks like a connection timeout (vs an intentional disconnect, a bond reset,
     * a clean close). Returns true if THIS event tripped the loop (a freshly-crossed threshold), so the
     * caller can log/surface the guide exactly once.
     */
    fun connectionEnded(wasBonded: Boolean, msSinceBond: Long?, timedOut: Boolean): Boolean {
        // Only a timeout that lands within the window after we actually bonded is evidence of the loop.
        // Anything else (never bonded, non-timeout close, a drop long after a healthy bond) breaks the
        // streak — a single healthy spell should clear prior suspicion.
        val bondThenQuickTimeout = wasBonded && timedOut &&
            (msSinceBond != null && msSinceBond <= quickTimeoutWindowMs)
        if (!bondThenQuickTimeout) {
            consecutiveBondTimeouts = 0
            return false
        }
        consecutiveBondTimeouts += 1
        if (!tripped && consecutiveBondTimeouts >= tripThreshold) {
            tripped = true
            return true        // freshly tripped — caller surfaces the re-pair guide once
        }
        return false
    }

    /**
     * Clear all suspicion: a clean session is flowing, or the user explicitly disconnected. Lets a
     * transient bond hiccup recover instead of permanently flagging the link as bond-looping.
     */
    fun reset() {
        consecutiveBondTimeouts = 0
        tripped = false
    }
}
