package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #78 hole-4 salvage-probe gate ([WhoopBleClient.shouldSalvageProbe]): the one bounded
 * app-foreground attempt while the #747 bond-loop pause is latched. This is what makes the give-up
 * provably unable to strand a strap the user has since freed (a genuine bond on the probe fully resets
 * the pause) while never re-entering the refusal hammer (probe frequency is capped at one per foreground
 * per [WhoopBleClient.BOND_LOOP_SALVAGE_FLOOR_MS] window, and the give-up stays latched throughout).
 * Twin of the Swift `BondLoopHardeningTests` probe cases.
 */
class BondLoopSalvageProbeTest {

    private val floor = WhoopBleClient.BOND_LOOP_SALVAGE_FLOOR_MS

    @Test
    fun firesPastFloorWhilePaused() {
        assertTrue(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = floor))
        assertTrue(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = floor + 3_600_000L))
    }

    @Test
    fun respectsTheFloor() {
        // Below the floor no probe fires - back-to-back foregrounds can't chain attempts.
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = floor - 1))
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = 0L))
    }

    @Test
    fun needsATripTimestamp() {
        // null ms = the pause never tripped this run = never probe.
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = null))
    }

    @Test
    fun onlyWhilePaused() {
        // Not paused (the normal healthy path) never probes - the probe exists ONLY for the latched pause.
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = false, connected = false,
            intentionalDisconnect = false, msSincePauseTripped = floor))
    }

    @Test
    fun suppressedWhenConnectedOrUserTornDown() {
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = true,
            intentionalDisconnect = false, msSincePauseTripped = floor))
        assertFalse(WhoopBleClient.shouldSalvageProbe(
            pausedForBondLoop = true, connected = false,
            intentionalDisconnect = true, msSincePauseTripped = floor))
    }
}
