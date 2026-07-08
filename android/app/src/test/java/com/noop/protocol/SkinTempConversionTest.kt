package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Device-family-aware skin-temp raw→°C conversion (#938). Mirrors the macOS `SkinTempConversionTests`.
 *
 * The historical `skin_temp_raw` register is on DIFFERENT scales per family: a CENTIDEGREE value on the
 * 5/MG v18 (@73) but a RAW ADC on the WHOOP 4.0 v24 (@72). A single family-blind `raw/100` sent every 4.0
 * night ~8 °C low, below the 28 °C worn gate, so skin temp + the illness signal vanished (issue #938,
 * reporter dpguglielmi's 4.0 capture: worn steady raw ~826, no-contact floor ~510).
 */
class SkinTempConversionTest {

    // ── WHOOP 5/MG (unchanged: raw/100 centidegrees) ────────────────────────

    @Test
    fun whoop5IsUnchangedCentidegrees() {
        assertEquals(30.57, skinTempCelsius(3057, DeviceFamily.WHOOP5), 1e-9)
        assertEquals(22.47, skinTempCelsius(2247, DeviceFamily.WHOOP5), 1e-9)
        assertEquals(34.0, skinTempCelsius(3400, DeviceFamily.WHOOP5), 1e-9)
    }

    // ── WHOOP 4.0 v24 (raw ADC map) ─────────────────────────────────────────

    @Test
    fun whoop4WornBaselineLandsInPlausibleBand() {
        for (raw in listOf(826, 830, 845, 859, 865)) {
            val c = skinTempCelsius(raw, DeviceFamily.WHOOP4)
            assertTrue("worn 4.0 raw $raw → $c °C must clear the 28 °C worn gate", c >= 28.0)
            assertTrue("worn 4.0 raw $raw → $c °C must stay under the 42 °C worn ceiling", c <= 42.0)
        }
        assertEquals(33.0, skinTempCelsius(826, DeviceFamily.WHOOP4), 1e-9)
    }

    @Test
    fun whoop4NoContactFloorIsBelowWornGate() {
        for (raw in listOf(506, 514, 520)) {
            assertTrue("4.0 no-contact floor raw $raw must fall below the worn gate",
                skinTempCelsius(raw, DeviceFamily.WHOOP4) < 28.0)
        }
    }

    @Test
    fun whoop4AndWhoop5DifferForTheSameRaw() {
        assertNotEquals(
            skinTempCelsius(826, DeviceFamily.WHOOP4),
            skinTempCelsius(826, DeviceFamily.WHOOP5),
            1e-6,
        )
    }

    @Test
    fun whoop4SyntheticFixtureRawIsPlausible() {
        val c = skinTempCelsius(900, DeviceFamily.WHOOP4)
        assertTrue(c > 28.0)
        assertTrue(c < 42.0)
    }
}
