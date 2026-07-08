package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Correction-math tests for the Hydration delete/undo path (#798). The single-total schema can't address
 * an individual log, so removing one is expressed as adjusting the day total; the contract is that the
 * total NEVER goes negative. These cover the pure core ([HydrationStore.clampedTotal] /
 * [HydrationStore.afterRemoving]) shared by the store's `set` + `remove`, so the clamp is verified without
 * a Room/repo stand-in.
 */
class HydrationRemoveTest {

    @Test fun clampedTotalFloorsAtZero() {
        assertEquals(0.0, HydrationStore.clampedTotal(-50.0), 0.0)
        assertEquals(0.0, HydrationStore.clampedTotal(0.0), 0.0)
        assertEquals(1200.0, HydrationStore.clampedTotal(1200.0), 0.0)
    }

    @Test fun removingSubtractsTheAmount() {
        // 737 = a Cup (237) undone from a day that had a Bottle (500) + Cup (237).
        assertEquals(500.0, HydrationStore.afterRemoving(737.0, 237), 0.0)
    }

    @Test fun removingMoreThanLoggedLandsOnEmptyNotNegative() {
        assertEquals(0.0, HydrationStore.afterRemoving(100.0, 500), 0.0)
    }

    @Test fun removingTheWholeTotalClearsTheDay() {
        // "Clear today" passes the full total as the amount.
        assertEquals(0.0, HydrationStore.afterRemoving(813.0, 813), 0.0)
    }

    @Test fun nonPositiveAmountIsANoOp() {
        assertEquals(300.0, HydrationStore.afterRemoving(300.0, 0), 0.0)
        assertEquals(300.0, HydrationStore.afterRemoving(300.0, -10), 0.0)
        // A no-op still clamps a (shouldn't-happen) negative current total.
        assertEquals(0.0, HydrationStore.afterRemoving(-5.0, 0), 0.0)
    }
}
