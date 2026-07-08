package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Test

/** Mirror of the Swift TestDomainTests: the id set, the import divergence, and the github labels MUST
 *  match the Swift TestDomain byte-for-byte (the cross-platform parity contract, spec section 10). */
class TestDomainTest {

    @Test fun fullIdSetMatchesSwift() {
        assertEquals(
            listOf(
                "universal", "sleep", "connection", "workouts", "display", "import",
                "steps", "notifications", "battery", "recovery", "hrv", "sources",
                "stress", "longevity", "master",
            ),
            TestDomain.values().map { it.id },
        )
    }

    @Test fun githubLabels() {
        assertEquals("test:all", TestDomain.MASTER.githubLabel)
        assertEquals("test:sleep", TestDomain.SLEEP.githubLabel)
        assertEquals("test:battery", TestDomain.BATTERY.githubLabel)
        assertEquals("test:import", TestDomain.IMPORT.githubLabel)
    }
}
