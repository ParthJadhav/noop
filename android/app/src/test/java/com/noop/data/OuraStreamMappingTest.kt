package com.noop.data

import com.noop.oura.OuraEvent
import com.noop.oura.OuraHR
import com.noop.oura.OuraHRV
import com.noop.oura.OuraIBI
import com.noop.oura.OuraSleepPhase
import com.noop.oura.OuraSleepStage
import com.noop.oura.OuraSpO2
import com.noop.oura.OuraTemp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM tests for [OuraStreamMapping], the pure fold of decoded Oura events onto the protocol Streams
 * shape (section-4 of the Oura local-BLE architecture plan). These pin the exact event kinds and
 * payload keys the Swift twin must match, the honest-data invariants (no fabricated channels, no
 * faked timestamps), and the SpO2/skinTemp widening onto the store.
 *
 * The anchor maps a ring-clock value to wall-clock unix seconds; tests use a trivial linear anchor so
 * the mapping logic (not a clock model) is what is under test.
 */
class OuraStreamMappingTest {

    /** Ring-clock 0 -> a fixed wall-clock base; +1 ring tick == +1 second. */
    private val base = 1_750_000_000
    private val anchor: (Long) -> Int? = { rt -> base + rt.toInt() }

    @Test
    fun hrAndIbiMapToHrAndRr() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.Hr(OuraHR(ringTimestamp = 10, bpm = 72, ibiMs = 833)),
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 10, ibiMs = 833)),
                OuraEvent.Ibi(OuraIBI(ringTimestamp = 11, ibiMs = 820)),
            ),
            anchor,
        )
        assertEquals(listOf(72), s.hr.map { it.bpm })
        assertEquals(listOf(base + 10), s.hr.map { it.ts })
        assertEquals(listOf(833, 820), s.rr.map { it.rrMs })
        assertEquals(listOf(base + 10, base + 11), s.rr.map { it.ts })
    }

    @Test
    fun hrvBecomesOuraHrvEventWithRawFieldsNotRmssd() {
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Hrv(OuraHRV(ringTimestamp = 5, timeMs = 1000, b1 = 7, b2 = -3))),
            anchor,
        )
        assertEquals(1, s.events.size)
        val ev = s.events.first()
        assertEquals(OuraStreamMapping.EVENT_HRV, ev.kind)
        assertEquals("OURA_HRV", ev.kind)
        assertEquals(base + 5, ev.ts)
        // HONEST: the ring's OWN raw tag fields only; NEVER a fabricated rmssd_ms.
        assertEquals(1000, ev.payload["time_ms"])
        assertEquals(7, ev.payload["b1"])
        assertEquals(-3, ev.payload["b2"])
        assertTrue("must not fabricate rmssd_ms", !ev.payload.containsKey("rmssd_ms"))
    }

    @Test
    fun sleepPhaseBecomesOuraSleepPhaseEvent() {
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.SleepPhaseEvent(OuraSleepPhase(ringTimestamp = 2, index = 0, stage = OuraSleepStage.DEEP)),
                OuraEvent.SleepPhaseEvent(OuraSleepPhase(ringTimestamp = 3, index = 1, stage = OuraSleepStage.REM)),
            ),
            anchor,
        )
        assertEquals(2, s.events.size)
        val deep = s.events[0]
        assertEquals(OuraStreamMapping.EVENT_SLEEP_PHASE, deep.kind)
        assertEquals("OURA_SLEEP_PHASE", deep.kind)
        assertEquals(2, deep.payload["phase"])           // OuraSleepStage.DEEP.raw == 2
        assertEquals(0, deep.payload["index"])
        assertEquals(3, s.events[1].payload["phase"])     // REM.raw == 3
        // PARITY: the payload is exactly { phase, index } - the Swift twin emits no phase_name, so neither
        // does Kotlin. Pin it so a re-added phase_name key breaks this test.
        assertNull(deep.payload["phase_name"])
    }

    @Test
    fun spo2UsesSingleChannelIrStaysZero() {
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Spo2(OuraSpO2(ringTimestamp = 1, value = 97))),
            anchor,
        )
        assertEquals(1, s.spo2.size)
        assertEquals(97, s.spo2.first().red)
        assertEquals(0, s.spo2.first().ir) // unread channel, never a fabricated second reading
        assertEquals(base + 1, s.spo2.first().ts)
    }

    @Test
    fun tempPersistsAsHundredthsOfDegree() {
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Temp(OuraTemp(ringTimestamp = 4, celsius = 33.27))),
            anchor,
        )
        assertEquals(1, s.skinTemp.size)
        assertEquals(3327, s.skinTemp.first().raw)
        assertEquals(base + 4, s.skinTemp.first().ts)
    }

    @Test
    fun unanchoredSamplesAreDroppedNotFaked() {
        // anchor returns null for ring time 99 -> that sample must be dropped, others kept.
        val partial: (Long) -> Int? = { rt -> if (rt == 99L) null else base + rt.toInt() }
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.Hr(OuraHR(ringTimestamp = 99, bpm = 60, ibiMs = 1000)),
                OuraEvent.Hr(OuraHR(ringTimestamp = 1, bpm = 61, ibiMs = 980)),
            ),
            partial,
        )
        assertEquals(listOf(61), s.hr.map { it.bpm })
    }

    @Test
    fun batteryIsNotPersistedAsAStreamRow() {
        // Battery has no ring timestamp; it flows via the live onBattery path, never a faked-ts row.
        val s = OuraStreamMapping.streams(
            listOf(OuraEvent.Battery(com.noop.oura.OuraBattery(percent = 88))),
            anchor,
        )
        assertTrue(s.battery.isEmpty())
        assertTrue(s.hr.isEmpty())
    }

    @Test
    fun tierBAndActivityInfoNeverMapToAStream() {
        // HONEST-DATA INVARIANT (PR #960): Tier-B raw summaries AND the decoded-but-unvalidated 0x50
        // activity/MET events must never produce a durable stream row (in particular no step count is
        // ever minted from MET - it is not one), exactly like the Swift twin's drop test.
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.TierB(
                    com.noop.oura.OuraTierBSummary(
                        tag = 0x7E, ringTimestamp = 100, rawPayload = intArrayOf(1, 2, 3),
                        kind = "real_steps",
                    ),
                ),
                OuraEvent.ActivityInfo(
                    com.noop.oura.OuraActivityInfo(ringTimestamp = 100, state = 0x41, met = listOf(1.8, 1.9)),
                ),
            ),
            anchor,
        )
        assertTrue(s.hr.isEmpty())
        assertTrue(s.rr.isEmpty())
        assertTrue(s.events.isEmpty())
        assertTrue(s.battery.isEmpty())
        assertTrue(s.spo2.isEmpty())
        assertTrue(s.skinTemp.isEmpty())
    }
}
