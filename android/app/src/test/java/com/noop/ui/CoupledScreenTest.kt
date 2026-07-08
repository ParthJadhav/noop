package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the pure display-only helpers behind the Coupled view (task #43) so they stay byte-identical to the
 * Swift [CoupledView] twin:
 *  - the OPTIMAL recovery->strain band mapping (green >= 67 -> 14-18, yellow 34-66 -> 10-14, red < 34 -> 4-10),
 *  - the strain band word thresholds (LIGHT/MODERATE/STRENUOUS/HIGH/ALL-OUT at 6/10/14/18 of 21),
 *  - the hours:minutes formatter.
 * These are display-only reads (never fed back into scoring), so the values here ARE the contract.
 */
class CoupledScreenTest {

    @Test fun optimalRange_greenDay_suggests14to18() {
        assertEquals("14 to 18", optimalStrainRangeText(90.0))
        assertEquals("14 to 18", optimalStrainRangeText(67.0)) // lower boundary of green is inclusive
    }

    @Test fun optimalRange_yellowDay_suggests10to14() {
        assertEquals("10 to 14", optimalStrainRangeText(66.9))
        assertEquals("10 to 14", optimalStrainRangeText(50.0))
        assertEquals("10 to 14", optimalStrainRangeText(34.0)) // lower boundary of yellow is inclusive
    }

    @Test fun optimalRange_redDay_suggests4to10() {
        assertEquals("4 to 10", optimalStrainRangeText(33.9))
        assertEquals("4 to 10", optimalStrainRangeText(10.0))
        assertEquals("4 to 10", optimalStrainRangeText(0.0))
    }

    @Test fun optimalRange_noRecovery_isNoData() {
        assertNull(optimalStrainRange(null))
        assertEquals("No Data", optimalStrainRangeText(null))
    }

    @Test fun optimalRange_bands_matchTheStruct() {
        assertEquals(OptimalStrainRange(14, 18), optimalStrainRange(80.0))
        assertEquals(OptimalStrainRange(10, 14), optimalStrainRange(40.0))
        assertEquals(OptimalStrainRange(4, 10), optimalStrainRange(5.0))
    }

    @Test fun strainBandWord_thresholds_matchTheGauge() {
        // Fractions of 21, matching the StrandDesign StrainGauge bands at 6/10/14/18.
        assertEquals("LIGHT", strainBandWord(4.0 / 21))
        assertEquals("MODERATE", strainBandWord(8.0 / 21))
        assertEquals("STRENUOUS", strainBandWord(12.0 / 21))
        assertEquals("HIGH", strainBandWord(16.0 / 21))
        assertEquals("ALL-OUT", strainBandWord(20.0 / 21))
        // Boundaries are exclusive-below: exactly 6/21 rolls into MODERATE.
        assertEquals("MODERATE", strainBandWord(6.0 / 21))
        assertEquals("STRENUOUS", strainBandWord(10.0 / 21))
        assertEquals("HIGH", strainBandWord(14.0 / 21))
        assertEquals("ALL-OUT", strainBandWord(18.0 / 21))
    }

    @Test fun hoursMinutes_formatsAsHandM() {
        assertEquals("6h 42m", hoursMinutes(402.0))
        assertEquals("7h 50m", hoursMinutes(470.0))
        assertEquals("0h 5m", hoursMinutes(5.0))
        assertEquals("8h 0m", hoursMinutes(480.0))
    }
}
