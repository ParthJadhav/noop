package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #801 parity: the cycle-awareness OPT-IN sex-gate ([cycleOptInApplies]). Cycle phase is derived from the
 * menstrual skin-temperature shift, so the opt-in invitation is offered only to profiles it can apply to
 * and is NOT shown for a male profile. Mirrors the iOS SkinTempSection.cycleOptInApplies
 * (`profile.sex.lowercased() != "male"`): female/nonbinary qualify, an unrecognised value defaults to
 * showing (rather than hiding). Pure-JVM.
 */
class CycleOptInGateTest {

    @Test fun maleProfileIsNotOfferedTheOptIn() {
        assertFalse(cycleOptInApplies("male"))
        assertFalse(cycleOptInApplies("Male"))   // case-insensitive
        assertFalse(cycleOptInApplies("MALE"))
    }

    @Test fun femaleAndNonbinaryAreOffered() {
        assertTrue(cycleOptInApplies("female"))
        assertTrue(cycleOptInApplies("nonbinary"))
    }

    @Test fun unrecognisedValueDefaultsToShowing() {
        // Default-show rather than hide, matching iOS: an empty / unexpected sex string still gets the card.
        assertTrue(cycleOptInApplies(""))
        assertTrue(cycleOptInApplies("unspecified"))
    }
}
