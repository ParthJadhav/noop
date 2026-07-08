package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/** The Android (t, soc) bank line must match the Swift "bank soc=.. t=..s" shape (#713, Test Centre).
 *  No em-dashes. */
class BatterySocLineFormatTest {

    @Test fun bankLineMatchesSwiftShape() {
        assertEquals("bank soc=80.0 t=1000s", BatterySocLine.format(80.0, 1000L))
    }
}
