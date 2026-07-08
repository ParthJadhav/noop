package com.noop.ble

import com.noop.testcentre.TestDomain
import org.junit.Assert.assertEquals
import org.junit.Test

/** The pure tag-formatting helper the WhoopBleClient.log() sink uses. Tagging happens AFTER redaction
 *  (the redactor is the single scrub point), so the tag prefix sits in front of an already-safe line. */
class StrapLogDomainTagTest {

    @Test fun nullDomainLeavesLineUntagged() {
        assertEquals("connected ok", taggedStrapLogLine("connected ok", null))
    }

    @Test fun domainPrefixesCompactMarker() {
        assertEquals("[sleep] gate run kept", taggedStrapLogLine("gate run kept", TestDomain.SLEEP))
    }

    @Test fun importUsesWireId() {
        assertEquals("[import] parsed 10 rows", taggedStrapLogLine("parsed 10 rows", TestDomain.IMPORT))
    }
}
