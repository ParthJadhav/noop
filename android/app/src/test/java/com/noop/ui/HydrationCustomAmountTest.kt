package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Custom-amount parse tests (#798) - the gate behind the Hydration "Custom amount" dialog's Log button.
 * The field accepts any whole ml in 1..3000; anything else (blank, zero, negative, non-numeric, over the
 * cap) either rejects (null → Log disabled) or clamps to the cap. Pure, so the dialog's confirm logic is
 * covered without composing UI.
 */
class HydrationCustomAmountTest {

    @Test fun parsesAPlainAmount() {
        assertEquals(250, parseCustomHydrationMl("250"))
        assertEquals(1, parseCustomHydrationMl("1"))
    }

    @Test fun trimsSurroundingWhitespace() {
        assertEquals(500, parseCustomHydrationMl("  500 "))
    }

    @Test fun rejectsBlankAndNonNumeric() {
        assertNull(parseCustomHydrationMl(""))
        assertNull(parseCustomHydrationMl("   "))
        assertNull(parseCustomHydrationMl("abc"))
        assertNull(parseCustomHydrationMl("12.5"))   // not a whole-ml integer
    }

    @Test fun rejectsZeroAndNegative() {
        assertNull(parseCustomHydrationMl("0"))
        assertNull(parseCustomHydrationMl("-100"))
    }

    @Test fun clampsToTheCap() {
        // The 3000 ml cap: anything above lands exactly on it rather than banking an absurd day.
        assertEquals(3000, parseCustomHydrationMl("3000"))
        assertEquals(3000, parseCustomHydrationMl("9999"))
    }
}
