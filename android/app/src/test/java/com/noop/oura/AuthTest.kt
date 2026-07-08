package com.noop.oura

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * AES auth known-answer + command-framing tests. Kotlin twin of the Swift AuthTests.swift.
 *
 * PARITY NOTE: the key, nonce, and expected proof/ciphertext hex below are byte-for-byte identical to
 * the Swift AuthTests fixtures. The proof vector was computed independently (raw AES-128-ECB no-pad
 * over nonce(15) || 0x01 || 0x10 x16) so it is a true cross-check of our AES path, NOT a
 * self-referential round-trip. The padding equivalence (explicit 0x10-block == AES/ECB/PKCS5Padding)
 * is what lets this Kotlin twin's javax.crypto path produce the same first ciphertext block.
 */
class AuthTest {
    private fun bytes(s: String) = OuraTestHex.bytes(s)
    private fun hex(b: IntArray) = OuraTestHex.hex(b)

    // MARK: - AES-128-ECB block known-answer (FIPS-197 C.1)

    @Test
    fun testAES128ECBKnownAnswerFIPS197() {
        // FIPS-197 appendix C.1: key 000102..0f, input 00112233445566778899aabbccddeeff
        // -> output 69c4e0d86a7b0430d8cdb78070b4c55a. Proves the AES core (javax.crypto path) is
        // correct before we trust the proof computation. Identical to the Swift fixture.
        val key = bytes("000102030405060708090a0b0c0d0e0f")
        val input = bytes("00112233445566778899aabbccddeeff")
        val out = aes128EcbEncryptNoPad(input, key)
        assertEquals("69c4e0d86a7b0430d8cdb78070b4c55a", hex(out))
    }

    // MARK: - Oura proof known-answer

    @Test
    fun testAuthProofKnownVector() {
        // Deterministic key + 15-byte nonce. Expected proof computed via independent raw AES-128-ECB
        // over nonce || 0x01 || (0x10 x16), first 16 ciphertext bytes. Identical to the Swift fixture.
        val key = bytes("000102030405060708090a0b0c0d0e0f")
        val nonce = bytes("0102030405060708090a0b0c0d0e0f")  // 15 bytes
        assertEquals(15, nonce.size)
        val proof = OuraAuth.computeProof(nonce, key)
        assertEquals("c49fb9e83c46087a555183a9dc511ee9", hex(proof))
    }

    @Test
    fun testProofIsExactlyFirstCipherBlock() {
        // The proof must be exactly the FIRST 16 ciphertext bytes, never the whole 32-byte output.
        val key = bytes("000102030405060708090a0b0c0d0e0f")
        val nonce = bytes("0102030405060708090a0b0c0d0e0f")
        val proof = OuraAuth.computeProof(nonce, key)
        assertEquals(16, proof.size)
    }

    // MARK: - Padding is load-bearing

    @Test
    fun testTrailingMarkerAndFullBlockPadChangeTheProof() {
        // If we (wrongly) used a DIFFERENT trailing marker the cipher input differs and block 1 (so
        // the proof) changes. This pins that the trailing 0x01 marker is load-bearing.
        val key = bytes("000102030405060708090a0b0c0d0e0f")
        val nonce = bytes("0102030405060708090a0b0c0d0e0f")
        val correct = OuraAuth.computeProof(nonce, key)

        // Same nonce, wrong marker (0x02 instead of 0x01) -> block 1 differs -> proof differs.
        val wrongPlain = nonce + intArrayOf(0x02) + IntArray(16) { 0x10 }
        val wrongCipher = aes128EcbEncryptNoPad(wrongPlain, key)
        assertNotEquals(
            "the trailing 0x01 marker is load-bearing; a different marker must change the proof",
            hex(correct),
            hex(wrongCipher.copyOfRange(0, 16)),
        )
    }

    // MARK: - Length guards

    @Test
    fun testBadKeyLengthThrows() {
        val e = assertThrows(OuraAuthException::class.java) {
            OuraAuth.computeProof(bytes("0102030405060708090a0b0c0d0e0f"), intArrayOf(0x00, 0x01))
        }
        assertEquals(OuraAuthException.Kind.BAD_KEY_LENGTH, e.kind)
    }

    @Test
    fun testBadNonceLengthThrows() {
        val e = assertThrows(OuraAuthException::class.java) {
            OuraAuth.computeProof(intArrayOf(0x00, 0x01), bytes("000102030405060708090a0b0c0d0e0f"))
        }
        assertEquals(OuraAuthException.Kind.BAD_NONCE_LENGTH, e.kind)
    }

    // MARK: - Command framing

    @Test
    fun testGetAuthNonceCommandBytes() {
        assertArrayEquals(intArrayOf(0x2F, 0x01, 0x2B), OuraAuth.getAuthNonceCommand())
    }

    @Test
    fun testInstallKeyCommandBytes() {
        val key = bytes("000102030405060708090a0b0c0d0e0f")
        val cmd = OuraAuth.installKeyCommand(key)
        assertArrayEquals(intArrayOf(0x24, 0x10), cmd.copyOfRange(0, 2))
        assertArrayEquals(key, cmd.copyOfRange(2, cmd.size))
    }

    @Test
    fun testSubmitProofCommandBytes() {
        val proof = bytes("c49fb9e83c46087a555183a9dc511ee9")
        val cmd = OuraAuth.submitProofCommand(proof)
        assertArrayEquals(intArrayOf(0x2F, 0x11, 0x2D), cmd.copyOfRange(0, 3))
        assertArrayEquals(proof, cmd.copyOfRange(3, cmd.size))
    }

    // MARK: - Secure-frame parsing of nonce / status

    @Test
    fun testNonceExtractedFromSecureFrame() {
        // Per s3.3 the response is `2f 10 2c <nonce:15>` where 0x10 is the LEN byte (16 body bytes:
        // 2c + 15 nonce). So subop is 0x2C and subBody = nonce.
        val nonce = bytes("0102030405060708090a0b0c0d0e0f")
        val frame = OuraSecureFrame(subop = 0x2C, subBody = nonce)
        assertArrayEquals(nonce, OuraAuth.nonce(frame))
    }

    @Test
    fun testAuthStatusParsed() {
        assertEquals(OuraAuthStatus.SUCCESS, OuraAuth.authStatus(OuraSecureFrame(0x2E, intArrayOf(0x00))))
        assertEquals(OuraAuthStatus.AUTH_ERROR, OuraAuth.authStatus(OuraSecureFrame(0x2E, intArrayOf(0x01))))
        assertEquals(OuraAuthStatus.IN_FACTORY_RESET, OuraAuth.authStatus(OuraSecureFrame(0x2E, intArrayOf(0x02))))
    }
}
