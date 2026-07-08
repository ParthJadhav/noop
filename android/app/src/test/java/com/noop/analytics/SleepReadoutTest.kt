package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SleepReadoutTest {
    private val dev = "test"
    private val start = 1_749_513_600L

    @Test fun hrDensityPerMinute() {
        // 600 samples over 599 s span -> ~60.1 samples/min.
        val hr = (0 until 600).map { HrSample(deviceId = dev, ts = start + it, bpm = 50) }
        assertEquals(60.1, SleepReadout.hrDensityPerMinute(hr), 0.2)
    }

    @Test fun hrDensityFewerThanTwoIsZero() {
        assertEquals(0.0, SleepReadout.hrDensityPerMinute(emptyList()), 0.0)
        assertEquals(0.0, SleepReadout.hrDensityPerMinute(listOf(HrSample(deviceId = dev, ts = start, bpm = 50))), 0.0)
    }

    @Test fun gravityCoverage() {
        val hr = (0 until 600).map { HrSample(deviceId = dev, ts = start + it, bpm = 50) }
        val grav = (0 until 600).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }
        assertTrue(SleepReadout.gravityCoverageFraction(grav, hr) > 0.9)
    }

    @Test fun gravityCoverageSparseIsBelowGate() {
        val hr = (0 until 600).map { HrSample(deviceId = dev, ts = start + it, bpm = 50) }
        val grav = (0 until 150).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }
        assertTrue(SleepReadout.gravityCoverageFraction(grav, hr) < SleepStager.sparseGravitySpanFrac)
    }

    @Test fun lastGateFired() {
        val tail = listOf(
            "[sleep] gate run=0 spanS=1800 DROPPED gate=minSleepMin spanMin=30 minSleepMin=60",
            "[sleep] gate run=1 spanS=5400 KEPT gate=accepted spanMin=90 eff=0.9 restingHR=50 daytime=false")
        assertEquals("accepted", SleepReadout.lastGateFired(tail))
    }

    @Test fun lastGateFiredNullWhenNoGateLine() {
        assertNull(SleepReadout.lastGateFired(listOf("[sleep] sleep day=2021-06-17 totalSleepMin=420")))
        assertNull(SleepReadout.lastGateFired(emptyList()))
    }
}
