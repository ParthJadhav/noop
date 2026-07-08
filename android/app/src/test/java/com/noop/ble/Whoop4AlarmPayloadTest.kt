package com.noop.ble

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the WHOOP 4.0 SET_ALARM_TIME (cmd 66) payload byte-for-byte ([whoop4AlarmPayload]).
 *
 * The earlier 7-byte form (`[0x01] + u32 LE epoch + [0x00, 0x00]`) made the strap ACK and log "armed"
 * but never buzz (#428). @ujix's btsnoop capture of the official WHOOP app on a real 4.0 (#535) showed
 * the official app always sends 9 bytes — the missing trailing `[0x00, 0x00]` is a haptic-mode field.
 * We now send the same 9 bytes; these tests pin that layout so it can't silently regress.
 *
 * NOTE: the buzz is confirmed on-device by the capture author (PR #535, 2026-06-20): a real WHOOP 4.0
 * buzzes at the specified time with this 9-byte frame. These tests pin the bytes we send; they do not
 * assert the strap wakes.
 */
class Whoop4AlarmPayloadTest {

    private fun bytes(vararg ints: Int): ByteArray = ByteArray(ints.size) { ints[it].toByte() }

    @Test
    fun length_isNineBytes() {
        assertEquals("official app sends 9 bytes — the 7-byte form never buzzed (#535)",
            9, whoop4AlarmPayload(1_000_000_000L).size)
    }

    @Test
    fun leadingByte_isFormByte0x01() {
        assertEquals(0x01.toByte(), whoop4AlarmPayload(0L)[0])
    }

    @Test
    fun epochField_isU32LittleEndian() {
        // 0x11223344 → LE: 0x44, 0x33, 0x22, 0x11
        val p = whoop4AlarmPayload(0x11223344L)
        assertArrayEquals(bytes(0x44, 0x33, 0x22, 0x11), p.copyOfRange(1, 5))
    }

    @Test
    fun subsecondsField_isAlwaysZero() {
        val p = whoop4AlarmPayload(1_781_912_880L)
        assertArrayEquals(bytes(0x00, 0x00), p.copyOfRange(5, 7))
    }

    @Test
    fun hapticModeField_isAlwaysZero() {
        val p = whoop4AlarmPayload(1_781_912_880L)
        assertArrayEquals("the missing 2 bytes from #535", bytes(0x00, 0x00), p.copyOfRange(7, 9))
    }

    /**
     * Whole-frame check against the captured epoch from @ujix's btsnoop log (#535).
     * 1781912880 = 0x6A35D530 → LE: 0x30, 0xD5, 0x35, 0x6A.
     */
    @Test
    fun wireCapture_epoch1781912880_matchesOfficialApp() {
        assertArrayEquals(
            bytes(0x01, 0x30, 0xD5, 0x35, 0x6A, 0x00, 0x00, 0x00, 0x00),
            whoop4AlarmPayload(1_781_912_880L),
        )
    }
}
