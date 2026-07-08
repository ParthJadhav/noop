package com.noop.data

import com.noop.protocol.SkinTempSample
import com.noop.protocol.Spo2Sample
import com.noop.protocol.Streams
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins that [StreamPersistence.toBatch] widens the live protocol [Streams]' new spo2/skinTemp lists
 * 1:1 onto the Room [StreamBatch] insert shape (so a live biometric source like the Oura ring lands
 * SpO2/skinTemp through the existing [WhoopRepository.insert] DAO inserts). A WHOOP batch (no
 * spo2/skinTemp) still produces empty lists, so the WHOOP path is unaffected.
 */
class StreamPersistenceSpo2SkinTempTest {

    @Test
    fun spo2AndSkinTempWidenOntoStreamBatch() {
        val streams = Streams(
            spo2 = mutableListOf(Spo2Sample(ts = 100, red = 97, ir = 0)),
            skinTemp = mutableListOf(SkinTempSample(ts = 101, raw = 3327)),
        )
        val batch = StreamPersistence.toBatch(streams)
        assertEquals(1, batch.spo2.size)
        assertEquals(100L, batch.spo2.first().ts)
        assertEquals(97, batch.spo2.first().red)
        assertEquals(0, batch.spo2.first().ir)
        assertEquals(1, batch.skinTemp.size)
        assertEquals(101L, batch.skinTemp.first().ts)
        assertEquals(3327, batch.skinTemp.first().raw)
    }

    @Test
    fun whoopBatchHasNoSpo2OrSkinTemp() {
        val streams = Streams(
            hr = mutableListOf(com.noop.protocol.HrSample(ts = 5, bpm = 70)),
        )
        val batch = StreamPersistence.toBatch(streams)
        assertEquals(1, batch.hr.size)
        assertEquals(0, batch.spo2.size)
        assertEquals(0, batch.skinTemp.size)
    }
}
