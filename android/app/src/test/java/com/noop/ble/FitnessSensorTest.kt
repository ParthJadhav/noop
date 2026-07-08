package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Spec-deterministic decode contract for the three standard fitness-sensor profiles — the JVM twin of
 * WhoopProtocol's FitnessSensorDecodeTests. Fixtures are built BYTE-BY-BYTE from the Bluetooth SIG RSC /
 * CSC / CPS specs (not real captures), asserting the exact flag→field mapping + fixed-point→unit scaling,
 * plus the pure [FitnessRateComputer] derivation (first-packet-yields-null honesty guard + clock wrap).
 * Pure decode → no android.bluetooth.
 */
class FitnessSensorTest {

    private fun bytes(vararg v: Int): ByteArray = ByteArray(v.size) { (v[it] and 0xFF).toByte() }
    private fun le16(v: Int): IntArray = intArrayOf(v and 0xFF, (v shr 8) and 0xFF)
    private fun le32(v: Long): IntArray = intArrayOf(
        (v and 0xFF).toInt(), ((v shr 8) and 0xFF).toInt(),
        ((v shr 16) and 0xFF).toInt(), ((v shr 24) and 0xFF).toInt(),
    )
    private fun pack(vararg parts: IntArray): ByteArray {
        val all = parts.flatMap { it.toList() }
        return ByteArray(all.size) { (all[it] and 0xFF).toByte() }
    }

    // MARK: - Running Speed and Cadence (0x2A53)

    @Test
    fun rscSpeedAndCadenceAlwaysPresent() {
        val data = pack(intArrayOf(0x00), le16(768), intArrayOf(170)) // 3.0 m/s, 170 spm, walking
        val r = FitnessSensor.runningSpeedCadence(data)!!
        assertEquals(FitnessSensor.SensorKind.RUNNING_SPEED_CADENCE, r.kind)
        assertEquals(3.0, r.speedMps!!, 0.0001)
        assertEquals(170, r.runningCadenceSpm)
        assertEquals(false, r.isRunning)
        assertEquals(10.8, r.speedKmh!!, 0.0001)
        assertNull(r.totalDistanceM)
    }

    @Test
    fun rscRunningFlagAndTotalDistanceWithStrideSkipped() {
        val data = pack(
            intArrayOf(0x07),              // stride + distance + running
            le16(1024), intArrayOf(88),    // 4.0 m/s, 88 spm
            le16(0x0190),                  // stride (skipped)
            le32(54321L),                  // distance raw → /10
        )
        val r = FitnessSensor.runningSpeedCadence(data)!!
        assertEquals(4.0, r.speedMps!!, 0.0001)
        assertEquals(88, r.runningCadenceSpm)
        assertEquals(true, r.isRunning)
        assertEquals(5432.1, r.totalDistanceM!!, 0.0001)
    }

    // MARK: - Cycling Speed and Cadence (0x2A5B)

    @Test
    fun cscWheelAndCrankRawFields() {
        val data = pack(intArrayOf(0x03), le32(100L), le16(2048), le16(50), le16(1024))
        val r = FitnessSensor.cyclingSpeedCadence(data)!!
        assertEquals(FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE, r.kind)
        assertEquals(100L, r.cumulativeWheelRevolutions)
        assertEquals(2048, r.lastWheelEventTime1024)
        assertEquals(50, r.cumulativeCrankRevolutions)
        assertEquals(1024, r.lastCrankEventTime1024)
        assertNull(r.speedMps)   // raw decode carries no instantaneous values
    }

    @Test
    fun cscCrankOnlyOmitsWheel() {
        val r = FitnessSensor.cyclingSpeedCadence(pack(intArrayOf(0x02), le16(77), le16(4096)))!!
        assertNull(r.cumulativeWheelRevolutions)
        assertEquals(77, r.cumulativeCrankRevolutions)
        assertEquals(4096, r.lastCrankEventTime1024)
    }

    // MARK: - Cycling Power Measurement (0x2A63)

    @Test
    fun cpsInstantaneousPowerAlwaysPresent() {
        val r = FitnessSensor.cyclingPower(pack(le16(0x0000), le16(243)))!!
        assertEquals(FitnessSensor.SensorKind.CYCLING_POWER, r.kind)
        assertEquals(243, r.instantaneousPowerWatts)
    }

    @Test
    fun cpsNegativePowerIsSigned() {
        val r = FitnessSensor.cyclingPower(pack(le16(0x0000), le16(0xFFFF)))!!
        assertEquals(-1, r.instantaneousPowerWatts)
    }

    @Test
    fun cpsCrankDataAfterSkippedOptionalsDecodesCleanly() {
        val flags = 0x0001 or 0x0004 or 0x0020   // pedal balance + torque + crank
        val data = pack(
            le16(flags), le16(200),       // power 200 W
            intArrayOf(60),               // pedal power balance (skip)
            le16(0x1234),                 // accumulated torque (skip)
            le16(42), le16(8192),         // crank revs 42, event 8192
        )
        val r = FitnessSensor.cyclingPower(data)!!
        assertEquals(200, r.instantaneousPowerWatts)
        assertEquals(42, r.cumulativeCrankRevolutions)
        assertEquals(8192, r.lastCrankEventTime1024)
    }

    @Test
    fun cpsWheelDataDecodesCleanly() {
        val r = FitnessSensor.cyclingPower(pack(le16(0x0010), le16(180), le32(500L), le16(1000)))!!
        assertEquals(180, r.instantaneousPowerWatts)
        assertEquals(500L, r.cumulativeWheelRevolutions)
        assertEquals(1000, r.lastWheelEventTime1024)
    }

    // MARK: - Rate computer (HONEST derivation)

    @Test
    fun rateComputerFirstPacketYieldsNull() {
        val rc = FitnessRateComputer(wheelCircumferenceM = 2.0)
        val first = FitnessSensor.Reading(
            FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
            cumulativeWheelRevolutions = 100L, lastWheelEventTime1024 = 1024,
            cumulativeCrankRevolutions = 10, lastCrankEventTime1024 = 1024,
        )
        val r = rc.update(first)
        assertNull(r.speedMps)
        assertNull(r.crankRpm)
    }

    @Test
    fun rateComputerDerivesSpeedAndCadenceFromTwoPackets() {
        val rc = FitnessRateComputer(wheelCircumferenceM = 2.0)
        rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeWheelRevolutions = 100L, lastWheelEventTime1024 = 1024,
                cumulativeCrankRevolutions = 10, lastCrankEventTime1024 = 1024,
            ),
        )
        val r = rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeWheelRevolutions = 105L, lastWheelEventTime1024 = 2048,
                cumulativeCrankRevolutions = 11, lastCrankEventTime1024 = 2048,
            ),
        )
        assertEquals(10.0, r.speedMps!!, 0.0001)
        assertEquals(36.0, r.speedKmh!!, 0.0001)
        assertEquals(60.0, r.crankRpm!!, 0.0001)
    }

    // MARK: - CPS wheel tick rate (PR #1007: 0x2A63 wheel event time is 1/2048 s, NOT 1/1024 s)

    @Test
    fun rateComputerCpsWheelEventTimeTicksAt2048() {
        // Real CPS timestamps → exact speed pin. 4096 ticks at 1/2048 s = 2 s (a /1024 bug would read
        // 4 s and halve this). +5 revs × 2.0 m over 2 s = 5 m/s.
        val rc = FitnessRateComputer(wheelCircumferenceM = 2.0)
        rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_POWER,
                cumulativeWheelRevolutions = 100L, lastWheelEventTime1024 = 2048,
            ),
        )
        val r = rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_POWER,
                cumulativeWheelRevolutions = 105L, lastWheelEventTime1024 = 6144,
            ),
        )
        assertEquals(5.0, r.speedMps!!, 0.0001)
        assertEquals(18.0, r.speedKmh!!, 0.0001)
    }

    @Test
    fun rateComputerCpsWheelDerivesDoubleTheCscSpeedForIdenticalBytes() {
        // Regression pin for the halved-speed bug: byte-identical counters/timestamps to the CSC
        // two-packet test above (1024-tick delta, +5 revs, 2.0 m wheel) must derive DOUBLE the speed on
        // a CPS source — 1024 ticks span 0.5 s at 1/2048 s, not 1 s. CSC on the same numbers pins 10 m/s.
        val rc = FitnessRateComputer(wheelCircumferenceM = 2.0)
        rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_POWER,
                cumulativeWheelRevolutions = 100L, lastWheelEventTime1024 = 1024,
            ),
        )
        val r = rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_POWER,
                cumulativeWheelRevolutions = 105L, lastWheelEventTime1024 = 2048,
            ),
        )
        assertEquals(20.0, r.speedMps!!, 0.0001)
        assertEquals(72.0, r.speedKmh!!, 0.0001)
    }

    @Test
    fun rateComputerCpsCrankStaysAt1024() {
        // Guard against over-correcting: CPS CRANK event time is 1/1024 s (same as CSC) — only the wheel
        // clock differs. +1 crank rev over 1024 ticks = 1 s = 60 rpm, NOT 120.
        val rc = FitnessRateComputer()
        rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_POWER,
                cumulativeCrankRevolutions = 10, lastCrankEventTime1024 = 1024,
            ),
        )
        val r = rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_POWER,
                cumulativeCrankRevolutions = 11, lastCrankEventTime1024 = 2048,
            ),
        )
        assertEquals(60.0, r.crankRpm!!, 0.0001)
    }

    @Test
    fun rateComputerWheelKindFlipYieldsNullThenReseeds() {
        // A 2A5B↔2A63 flip means the baseline timestamp is on a DIFFERENT clock base (1/1024 vs 1/2048 s)
        // — a cross-base delta would fabricate a speed, so the first post-flip packet must yield null and
        // re-seed the baseline. The packet AFTER that derives normally on the new base.
        val rc = FitnessRateComputer(wheelCircumferenceM = 2.0)
        rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeWheelRevolutions = 100L, lastWheelEventTime1024 = 1024,
            ),
        )
        val flip = rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_POWER,
                cumulativeWheelRevolutions = 105L, lastWheelEventTime1024 = 2048,
            ),
        )
        assertNull(flip.speedMps)   // never a speed computed across mixed clocks
        val settled = rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_POWER,
                cumulativeWheelRevolutions = 110L, lastWheelEventTime1024 = 4096,
            ),
        )
        assertEquals(10.0, settled.speedMps!!, 0.0001)   // 5 revs × 2 m over 2048/2048 = 1 s
        // Flip back the other way: same rule, null again.
        val flipBack = rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeWheelRevolutions = 115L, lastWheelEventTime1024 = 5120,
            ),
        )
        assertNull(flipBack.speedMps)
    }

    @Test
    fun rateComputerNoNewRevolutionYieldsNull() {
        val rc = FitnessRateComputer()
        rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeCrankRevolutions = 50, lastCrankEventTime1024 = 1000,
            ),
        )
        val r = rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeCrankRevolutions = 50, lastCrankEventTime1024 = 1000,
            ),
        )
        assertNull(r.crankRpm)
    }

    @Test
    fun rateComputerHandlesEventTimeWrap() {
        val rc = FitnessRateComputer(wheelCircumferenceM = 2.0)
        rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeWheelRevolutions = 1000L, lastWheelEventTime1024 = 65000,
            ),
        )
        val r = rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeWheelRevolutions = 1005L, lastWheelEventTime1024 = 488,
            ),
        )
        assertEquals(10.0, r.speedMps!!, 0.0001)
    }

    @Test
    fun rateComputerHandlesCrankCounterWrap() {
        val rc = FitnessRateComputer()
        rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeCrankRevolutions = 65534, lastCrankEventTime1024 = 1024,
            ),
        )
        val r = rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeCrankRevolutions = 1, lastCrankEventTime1024 = 2048,
            ),
        )
        assertEquals(180.0, r.crankRpm!!, 0.0001)
    }

    @Test
    fun rateComputerResetClearsBaseline() {
        val rc = FitnessRateComputer(wheelCircumferenceM = 2.0)
        rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeWheelRevolutions = 100L, lastWheelEventTime1024 = 1024,
            ),
        )
        rc.reset()
        val r = rc.update(
            FitnessSensor.Reading(
                FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
                cumulativeWheelRevolutions = 200L, lastWheelEventTime1024 = 2048,
            ),
        )
        assertNull(r.speedMps)
    }

    // MARK: - Robustness over UNTRUSTED / malformed input

    @Test
    fun emptyAndShortBuffersNeverCrash() {
        assertNull(FitnessSensor.runningSpeedCadence(ByteArray(0)))
        assertNull(FitnessSensor.cyclingSpeedCadence(ByteArray(0)))
        assertNull(FitnessSensor.cyclingPower(bytes(0x00)))   // flags need 2 bytes
        val r = FitnessSensor.runningSpeedCadence(bytes(0x00, 0x10))
        assertNotNull(r)
        assertNull(r!!.speedMps)
    }

    @Test
    fun hugeBufferIsBounded() {
        val junk = IntArray(5000) { 0xAB }
        val r = FitnessSensor.cyclingPower(pack(le16(0x0000), le16(321), junk))!!
        assertEquals(321, r.instantaneousPowerWatts)
    }

    @Test
    fun decodeByUuidDispatch() {
        assertEquals(
            FitnessSensor.SensorKind.RUNNING_SPEED_CADENCE,
            FitnessSensor.decode("2a53", pack(intArrayOf(0x00), le16(256), intArrayOf(60)))?.kind,
        )
        assertEquals(
            FitnessSensor.SensorKind.CYCLING_SPEED_CADENCE,
            FitnessSensor.decode("2A5B", pack(intArrayOf(0x02), le16(1), le16(1)))?.kind,
        )
        assertEquals(
            FitnessSensor.SensorKind.CYCLING_POWER,
            FitnessSensor.decode("2A63", pack(le16(0), le16(0)))?.kind,
        )
        assertNull(FitnessSensor.decode("1234", bytes(0x00, 0x00)))
        assertTrue(true)
    }
}
