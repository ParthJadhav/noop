package com.noop.oura

import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

// Auth: the application-level challenge handshake (OURA_PROTOCOL.md s3). Kotlin twin of Auth.swift.
// Three independent key layers exist (link-layer LTK, LE-privacy IRK, application auth_key); this
// module concerns ONLY the 16-byte application auth_key challenge, which is session-scoped (re-run on
// every new BLE connection).
//
// The challenge is AES-128/ECB:
//   plaintext = nonce(15) || 0x01      -> 16 bytes
//   then PKCS5/PKCS7 FULL-BLOCK pad     -> append 0x10 x16, 32 bytes total
//   proof = AES_128_ECB(auth_key, plaintext_with_pad)[:16]      (first ciphertext block)
// The trailing 0x01 byte and the full-block 0x10 padding are load-bearing (OURA_PROTOCOL.md s3.4):
// the ring computes the same and compares the first block. We pin the padding explicitly.
//
// PADDING EQUIVALENCE (the brief calls this out): because block 1 (nonce||0x01) is already a full
// 16-byte block, "AES/ECB/PKCS5Padding" over that single block appends exactly the 0x10 x16 block
// we construct here, so PKCS5Padding(block1)[:16] == NoPadding(block1 || 0x10x16)[:16]. This twin
// builds the explicit 32-byte plaintext and runs "AES/ECB/NoPadding" so the byte layout is pinned
// and the first-block proof is identical to the Swift port (and to a PKCS5 path). Key is injected,
// NEVER hardcoded.
//
// Platform-pure value types (no android.bluetooth). Facts cited per OURA_PROTOCOL.md s3.

/**
 * Result of submitting the auth proof (status byte of the 0x2E response, OURA_PROTOCOL.md s3.5).
 */
enum class OuraAuthStatus(val raw: Int) {
    SUCCESS(0x00),
    AUTH_ERROR(0x01),          // wrong key
    IN_FACTORY_RESET(0x02),    // need 0x24 key install first
    NOT_ORIGINAL_DEVICE(0x03);

    val isSuccess: Boolean get() = this == SUCCESS

    companion object {
        private val byRaw = entries.associateBy { it.raw }
        fun fromRaw(raw: Int): OuraAuthStatus? = byRaw[raw]
    }
}

/**
 * Errors the pure auth state machine can surface (no throwing into BLE; the driver maps these to
 * honest "needsPairing"/retry states).
 */
class OuraAuthException(val kind: Kind) : Exception(kind.name) {
    enum class Kind {
        BAD_KEY_LENGTH,     // auth_key must be exactly 16 bytes
        BAD_NONCE_LENGTH,   // nonce must be exactly 15 bytes
        ENCRYPTION_FAILED,
    }
}

object OuraAuth {
    /** Expected sizes, per OURA_PROTOCOL.md s3. */
    const val keyLength = 16
    const val nonceLength = 15
    const val proofLength = 16

    /** The trailing marker byte appended to the nonce before encryption. Per OURA_PROTOCOL.md s3.4. */
    const val trailingMarker = 0x01

    /** PKCS full-block pad byte (a 16-byte block of value 0x10). Per OURA_PROTOCOL.md s3.4. */
    const val padByte = 0x10

    // MARK: - Outgoing commands

    /** Build the GetAuthNonce request: `2f 01 2b` (secure-session sub-op 0x01). Per OURA_PROTOCOL.md s3.3. */
    fun getAuthNonceCommand(): IntArray = intArrayOf(0x2F, 0x01, 0x2B)

    /**
     * Build the SetAuthKey command used once after a factory reset to provision our 16-byte key:
     * `24 10 <16-byte key>`. Per OURA_PROTOCOL.md s3.2. Throws on a wrong-length key. This installs a
     * key into the ring, so callers gate it behind an explicit, named provisioning flow.
     */
    fun installKeyCommand(key: IntArray): IntArray {
        if (key.size != keyLength) throw OuraAuthException(OuraAuthException.Kind.BAD_KEY_LENGTH)
        return intArrayOf(0x24, 0x10) + key
    }

    /**
     * Extract the 15-byte nonce from a parsed secure sub-frame whose subop is 0x10/0x2C
     * (`2f 10 2c <nonce:15>`). Returns null when the subop is not a nonce response or the length is
     * wrong. Per OURA_PROTOCOL.md s3.3 / s4.2.
     */
    fun nonce(frame: OuraSecureFrame): IntArray? {
        // The nonce response carries the nonce bytes directly as the sub-body. Accept the canonical
        // 0x10 nonce-response subop (alias 0x2C is the same view). A 15-byte body is required.
        if (frame.subop != 0x10 && frame.subop != 0x2C) return null
        if (frame.subBody.size != nonceLength) return null
        return frame.subBody
    }

    /**
     * Compute the 16-byte proof from a 15-byte nonce and the 16-byte auth_key:
     *   AES_128_ECB(auth_key, nonce(15) || 0x01 || pad(0x10 x16))[:16]
     * Per OURA_PROTOCOL.md s3.4. Throws on bad input lengths or a cipher failure. The padding is
     * constructed explicitly (NOT via a library's auto-pad) so the byte layout is pinned and testable.
     */
    fun computeProof(nonce: IntArray, key: IntArray): IntArray {
        if (key.size != keyLength) throw OuraAuthException(OuraAuthException.Kind.BAD_KEY_LENGTH)
        if (nonce.size != nonceLength) throw OuraAuthException(OuraAuthException.Kind.BAD_NONCE_LENGTH)
        // plaintext block 1: nonce(15) || 0x01  -> exactly 16 bytes.
        // PKCS#7 full-block pad: because block 1 is already a full block, the pad is a whole extra
        // block of 0x10 x16. This is the load-bearing detail from OURA_PROTOCOL.md s3.4.
        val plaintext = nonce + intArrayOf(trailingMarker) + IntArray(keyLength) { padByte }
        // 32-byte plaintext (2 blocks). Encrypt with raw ECB (no auto-padding), take the first block.
        val cipher = aes128EcbEncryptNoPad(plaintext, key)
        if (cipher.size < proofLength) throw OuraAuthException(OuraAuthException.Kind.ENCRYPTION_FAILED)
        return cipher.copyOfRange(0, proofLength)
    }

    /** Build the Authenticate (submit-proof) command: `2f 11 2d <proof:16>`. Per OURA_PROTOCOL.md s3.5. */
    fun submitProofCommand(proof: IntArray): IntArray {
        if (proof.size != proofLength) throw OuraAuthException(OuraAuthException.Kind.ENCRYPTION_FAILED)
        return intArrayOf(0x2F, 0x11, 0x2D) + proof
    }

    /** One-shot helper: nonce + key -> the ready-to-write Authenticate command. Per OURA_PROTOCOL.md s3.4-3.5. */
    fun authenticateCommand(nonce: IntArray, key: IntArray): IntArray =
        submitProofCommand(computeProof(nonce, key))

    // MARK: - Incoming status

    /**
     * Parse the handshake-completion status from a 0x2E sub-frame (`2f 02 2e <status>`).
     * Per OURA_PROTOCOL.md s3.5. Returns null when the subop is not 0x2E or the status byte is absent.
     */
    fun authStatus(frame: OuraSecureFrame): OuraAuthStatus? {
        if (frame.subop != 0x2E || frame.subBody.isEmpty()) return null
        return OuraAuthStatus.fromRaw(frame.subBody[0])
    }
}

// MARK: - AES-128 ECB (raw, no padding)

/**
 * Encrypt `data` (a multiple of 16 bytes) under AES-128 in ECB mode with NO padding applied by the
 * cipher (we pad explicitly upstream). Kotlin uses javax.crypto "AES/ECB/NoPadding"; the brief notes
 * the PKCS5 equivalence (PKCS5Padding over the single nonce||0x01 block yields the same first block),
 * documented in Auth above. Throws on a bad key length or a non-block-aligned input.
 *
 * `data` and `key` are unsigned-byte IntArrays (0..255), matching the rest of the package; the
 * returned ciphertext is the same shape.
 */
fun aes128EcbEncryptNoPad(data: IntArray, key: IntArray): IntArray {
    if (key.size != 16) throw OuraAuthException(OuraAuthException.Kind.BAD_KEY_LENGTH)
    if (data.size % 16 != 0) throw OuraAuthException(OuraAuthException.Kind.ENCRYPTION_FAILED)
    return try {
        val cipher = Cipher.getInstance("AES/ECB/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(ByteArray(16) { key[it].toByte() }, "AES"))
        val out = cipher.doFinal(ByteArray(data.size) { data[it].toByte() })
        IntArray(out.size) { out[it].toInt() and 0xFF }
    } catch (e: Exception) {
        throw OuraAuthException(OuraAuthException.Kind.ENCRYPTION_FAILED)
    }
}
