package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

/**
 * Swift-parity twin of HRVFreqDomainTests.swift, frequency-domain HRV via Lomb-Scargle on the (uneven)
 * tachogram. Verifies the Task-Force span gates (HF >= 60 s, LF >= 250 s) and that a band-limited
 * sinusoidal modulation puts its power in the expected band.
 */
class HrvFreqDomainTest {

    /** Synthetic R-R series whose interval is sinusoidally modulated at modHz around baseMs; the beat times
     *  are the running cumulative sum of the generated intervals (a genuine unevenly-sampled tachogram). */
    private fun modulatedRR(baseMs: Double, ampMs: Double, modHz: Double, durationSec: Double): List<Double> {
        val out = ArrayList<Double>()
        var t = 0.0
        while (t < durationSec) {
            val rr = baseMs + ampMs * sin(2.0 * PI * modHz * t)
            out.add(rr)
            t += rr / 1000.0
        }
        return out
    }

    @Test
    fun abstainsUnderSixtySecondSpan() {
        val rr = modulatedRR(1000.0, 20.0, 0.25, 40.0)
        assertNull(HrvFreqDomain.freqDomainRaw(rr))
    }

    @Test
    fun tooFewBeatsAbstains() {
        val rr = List(HrvFreqDomain.MIN_BEATS - 1) { 1000.0 }
        assertNull(HrvFreqDomain.freqDomainRaw(rr))
    }

    @Test
    fun shortSpanGivesHFButNullLF() {
        val rr = modulatedRR(900.0, 25.0, 0.25, 120.0)
        val bands = HrvFreqDomain.freqDomainRaw(rr)
        assertNotNull(bands)
        assertNull("LF must be null below the 250 s span gate", bands!!.lf)
        assertNull("LF/HF must be null when LF is null", bands.lfhf)
        assertTrue(bands.hf > 0)
        assertEquals(bands.hf, bands.totalPower, 1e-9)
    }

    @Test
    fun longSpanGivesLFAndRatio() {
        val rr = modulatedRR(900.0, 25.0, 0.25, 300.0)
        val bands = HrvFreqDomain.freqDomainRaw(rr)
        assertNotNull(bands)
        assertNotNull(bands!!.lf)
        assertNotNull(bands.lfhf)
        assertTrue("wide total power must exceed HF alone once LF is in", bands.totalPower > bands.hf)
    }

    @Test
    fun hfModulationConcentratesPowerInHF() {
        val rr = modulatedRR(900.0, 30.0, 0.25, 300.0)
        val bands = HrvFreqDomain.freqDomainRaw(rr)!!
        assertNotNull(bands.lf)
        assertTrue("HF-band modulation must dominate the HF band", bands.hf > bands.lf!! * 3.0)
        assertTrue("an HF-dominant rhythm has LF/HF < 1", bands.lfhf!! < 1.0)
    }

    @Test
    fun lfModulationConcentratesPowerInLF() {
        val rr = modulatedRR(900.0, 30.0, 0.10, 300.0)
        val bands = HrvFreqDomain.freqDomainRaw(rr)!!
        assertNotNull(bands.lf)
        assertTrue("LF-band modulation must dominate the LF band", bands.lf!! > bands.hf * 3.0)
        assertTrue("an LF-dominant rhythm has LF/HF > 1", bands.lfhf!! > 1.0)
    }

    @Test
    fun cleanRRSharedWithTimeDomainPath() {
        val rr = ArrayList(modulatedRR(900.0, 25.0, 0.25, 300.0))
        rr.add(rr.size / 2, 50.0)   // out-of-range artifact, range-filtered away
        val bands = HrvFreqDomain.freqDomainRaw(rr)
        assertNotNull(bands)
        assertTrue(bands!!.hf.isFinite() && bands.hf > 0)
    }
}
