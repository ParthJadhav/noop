import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// Auth: the application-level challenge handshake (OURA_PROTOCOL.md s3). Three independent key layers
// exist (link-layer LTK, LE-privacy IRK, application auth_key); this module concerns ONLY the 16-byte
// application auth_key challenge, which is session-scoped (re-run on every new BLE connection).
//
// The challenge is AES-128/ECB:
//   plaintext = nonce(15) || 0x01      -> 16 bytes
//   then PKCS5/PKCS7 FULL-BLOCK pad     -> append 0x10 x16, 32 bytes total
//   proof = AES_128_ECB(auth_key, plaintext_with_pad)[:16]      (first ciphertext block)
// The trailing 0x01 byte and the full-block 0x10 padding are load-bearing (OURA_PROTOCOL.md s3.4):
// the ring computes the same and compares the first block. We pin the padding explicitly.
//
// CryptoKit has no raw AES-ECB, so on Apple platforms we use a thin CommonCrypto ECB wrapper. On
// platforms without CommonCrypto (Linux CI / headless test) a self-contained AES-128 ECB block
// cipher is used so the known-answer test runs anywhere. The Kotlin twin uses javax.crypto
// "AES/ECB/PKCS5Padding". Key is injected, NEVER hardcoded.
//
// Platform-pure value types (no CoreBluetooth). Facts cited per OURA_PROTOCOL.md s3.

/// Result of submitting the auth proof (status byte of the 0x2E response, OURA_PROTOCOL.md s3.5).
public enum OuraAuthStatus: UInt8, Sendable, Equatable, Codable {
    case success            = 0x00
    case authError          = 0x01   // wrong key
    case inFactoryReset     = 0x02   // need 0x24 key install first
    case notOriginalDevice  = 0x03

    public var isSuccess: Bool { self == .success }
}

/// Errors the pure auth state machine can surface (no throwing into BLE; the driver maps these to
/// honest "needsPairing"/retry states).
public enum OuraAuthError: Error, Equatable {
    case badKeyLength           // auth_key must be exactly 16 bytes
    case badNonceLength         // nonce must be exactly 15 bytes
    case encryptionFailed
}

public enum OuraAuth {
    /// Expected sizes, per OURA_PROTOCOL.md s3.
    public static let keyLength = 16
    public static let nonceLength = 15
    public static let proofLength = 16
    /// The trailing marker byte appended to the nonce before encryption. Per OURA_PROTOCOL.md s3.4.
    public static let trailingMarker: UInt8 = 0x01
    /// PKCS full-block pad byte (a 16-byte block of value 0x10). Per OURA_PROTOCOL.md s3.4.
    public static let padByte: UInt8 = 0x10

    // MARK: - Outgoing commands

    /// Build the GetAuthNonce request: `2f 01 2b` (secure-session sub-op 0x01). Per OURA_PROTOCOL.md s3.3.
    public static func getAuthNonceCommand() -> [UInt8] {
        [0x2F, 0x01, 0x2B]
    }

    /// Build the SetAuthKey command used once after a factory reset to provision our 16-byte key:
    /// `24 10 <16-byte key>`. Per OURA_PROTOCOL.md s3.2. Throws on a wrong-length key. This installs
    /// a key into the ring, so callers gate it behind an explicit, named provisioning flow.
    public static func installKeyCommand(_ key: [UInt8]) throws -> [UInt8] {
        guard key.count == keyLength else { throw OuraAuthError.badKeyLength }
        return [0x24, 0x10] + key
    }

    /// Extract the 15-byte nonce from a parsed secure sub-frame whose subop is 0x10/0x2C
    /// (`2f 10 2c <nonce:15>`). Returns nil when the subop is not a nonce response or the length is
    /// wrong. Per OURA_PROTOCOL.md s3.3 / s4.2.
    public static func nonce(from frame: OuraSecureFrame) -> [UInt8]? {
        // The nonce response carries the nonce bytes directly as the sub-body. Accept the canonical
        // 0x10 nonce-response subop (alias 0x2C is the same view). A 15-byte body is required.
        guard frame.subop == 0x10 || frame.subop == 0x2C else { return nil }
        guard frame.subBody.count == nonceLength else { return nil }
        return frame.subBody
    }

    /// Compute the 16-byte proof from a 15-byte nonce and the 16-byte auth_key:
    ///   AES_128_ECB(auth_key, nonce(15) || 0x01 || pad(0x10 x16))[:16]
    /// Per OURA_PROTOCOL.md s3.4. Throws on bad input lengths or a cipher failure. The padding is
    /// constructed explicitly (NOT via a library's auto-pad) so the byte layout is pinned and testable.
    public static func computeProof(nonce: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard key.count == keyLength else { throw OuraAuthError.badKeyLength }
        guard nonce.count == nonceLength else { throw OuraAuthError.badNonceLength }
        // plaintext block 1: nonce(15) || 0x01  -> exactly 16 bytes.
        var plaintext = nonce
        plaintext.append(trailingMarker)
        // PKCS#7 full-block pad: because block 1 is already a full block, the pad is a whole extra
        // block of 0x10 x16. This is the load-bearing detail from OURA_PROTOCOL.md s3.4.
        plaintext.append(contentsOf: [UInt8](repeating: padByte, count: keyLength))
        // 32-byte plaintext (2 blocks). Encrypt with raw ECB (no auto-padding), take the first block.
        let cipher = try aes128EcbEncryptNoPad(plaintext, key: key)
        guard cipher.count >= proofLength else { throw OuraAuthError.encryptionFailed }
        return Array(cipher[0..<proofLength])
    }

    /// Build the Authenticate (submit-proof) command: `2f 11 2d <proof:16>`. Per OURA_PROTOCOL.md s3.5.
    public static func submitProofCommand(_ proof: [UInt8]) throws -> [UInt8] {
        guard proof.count == proofLength else { throw OuraAuthError.encryptionFailed }
        return [0x2F, 0x11, 0x2D] + proof
    }

    /// One-shot helper: nonce + key -> the ready-to-write Authenticate command. Per OURA_PROTOCOL.md s3.4-3.5.
    public static func authenticateCommand(nonce: [UInt8], key: [UInt8]) throws -> [UInt8] {
        let proof = try computeProof(nonce: nonce, key: key)
        return try submitProofCommand(proof)
    }

    // MARK: - Incoming status

    /// Parse the handshake-completion status from a 0x2E sub-frame (`2f 02 2e <status>`).
    /// Per OURA_PROTOCOL.md s3.5. Returns nil when the subop is not 0x2E or the status byte is absent.
    public static func authStatus(from frame: OuraSecureFrame) -> OuraAuthStatus? {
        guard frame.subop == 0x2E, let raw = frame.subBody.first else { return nil }
        return OuraAuthStatus(rawValue: raw)
    }
}

// MARK: - AES-128 ECB (raw, no padding)

/// Encrypt `data` (a multiple of 16 bytes) under AES-128 in ECB mode with NO padding applied by the
/// cipher (we pad explicitly upstream). On Apple platforms this uses CommonCrypto; elsewhere a
/// self-contained AES-128 block cipher runs so the known-answer test passes on any CI.
func aes128EcbEncryptNoPad(_ data: [UInt8], key: [UInt8]) throws -> [UInt8] {
    guard key.count == 16 else { throw OuraAuthError.badKeyLength }
    guard data.count % 16 == 0 else { throw OuraAuthError.encryptionFailed }
#if canImport(CommonCrypto)
    // Pass the arrays directly: Swift bridges [UInt8] to the Unsafe(Mutable)Pointer parameters without
    // nesting withUnsafeBytes closures (nesting them over scope-aliased buffers trips Swift's runtime
    // exclusive-access check). ECB takes no IV. No kCCOptionPKCS7Padding: padding is explicit upstream.
    var out = [UInt8](repeating: 0, count: data.count)
    var moved = 0
    let status = CCCrypt(
        CCOperation(kCCEncrypt),
        CCAlgorithm(kCCAlgorithmAES),
        CCOptions(kCCOptionECBMode),
        key, key.count,
        nil,
        data, data.count,
        &out, out.count,
        &moved
    )
    guard status == kCCSuccess, moved == data.count else { throw OuraAuthError.encryptionFailed }
    return out
#else
    // Portable fallback: encrypt each 16-byte block with the pure AES-128 core.
    let aes = AES128(key: key)
    var out = [UInt8]()
    out.reserveCapacity(data.count)
    var i = 0
    while i < data.count {
        out.append(contentsOf: aes.encryptBlock(Array(data[i..<(i + 16)])))
        i += 16
    }
    return out
#endif
}

#if !canImport(CommonCrypto)
// Minimal, original AES-128 block cipher (FIPS-197) for non-Apple CI parity ONLY. Apple builds use
// CommonCrypto above. Single-block ECB; key schedule + rounds written from the published standard.
struct AES128 {
    private var roundKeys: [[UInt8]]

    private static let sbox: [UInt8] = {
        // Standard AES S-box (FIPS-197 Figure 7).
        var s = [UInt8](repeating: 0, count: 256)
        let table: [UInt8] = [
            0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
            0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
            0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
            0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
            0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
            0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
            0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
            0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
            0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
            0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
            0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
            0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
            0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
            0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
            0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
            0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
        ]
        for i in 0..<256 { s[i] = table[i] }
        return s
    }()

    private static let rcon: [UInt8] = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36]

    init(key: [UInt8]) {
        roundKeys = AES128.expandKey(key)
    }

    private static func xtime(_ a: UInt8) -> UInt8 {
        let hi = (a & 0x80) != 0
        let shifted = a << 1
        return hi ? (shifted ^ 0x1b) : shifted
    }

    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var aa = a
        var bb = b
        for _ in 0..<8 {
            if (bb & 1) != 0 { result ^= aa }
            aa = xtime(aa)
            bb >>= 1
        }
        return result
    }

    private static func expandKey(_ key: [UInt8]) -> [[UInt8]] {
        // 11 round keys (4 words each) for AES-128, as 16-byte arrays.
        var words: [[UInt8]] = []
        for i in 0..<4 { words.append([key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]]) }
        for i in 4..<44 {
            var temp = words[i - 1]
            if i % 4 == 0 {
                temp = [temp[1], temp[2], temp[3], temp[0]]          // RotWord
                temp = temp.map { sbox[Int($0)] }                    // SubWord
                temp[0] ^= rcon[i / 4 - 1]
            }
            let prev = words[i - 4]
            words.append([prev[0] ^ temp[0], prev[1] ^ temp[1], prev[2] ^ temp[2], prev[3] ^ temp[3]])
        }
        var rks: [[UInt8]] = []
        for r in 0..<11 {
            var rk = [UInt8]()
            for c in 0..<4 { rk.append(contentsOf: words[r * 4 + c]) }
            rks.append(rk)
        }
        return rks
    }

    func encryptBlock(_ input: [UInt8]) -> [UInt8] {
        // state is column-major (state[r + 4c]).
        var state = input
        addRoundKey(&state, roundKeys[0])
        for round in 1..<10 {
            subBytes(&state)
            shiftRows(&state)
            mixColumns(&state)
            addRoundKey(&state, roundKeys[round])
        }
        subBytes(&state)
        shiftRows(&state)
        addRoundKey(&state, roundKeys[10])
        return state
    }

    private func addRoundKey(_ s: inout [UInt8], _ rk: [UInt8]) {
        for i in 0..<16 { s[i] ^= rk[i] }
    }

    private func subBytes(_ s: inout [UInt8]) {
        for i in 0..<16 { s[i] = AES128.sbox[Int(s[i])] }
    }

    private func shiftRows(_ s: inout [UInt8]) {
        // Rows are s[r], s[r+4], s[r+8], s[r+12]; rotate row r left by r.
        var t = s
        for r in 1..<4 {
            for c in 0..<4 {
                t[r + 4 * c] = s[r + 4 * ((c + r) % 4)]
            }
        }
        s = t
    }

    private func mixColumns(_ s: inout [UInt8]) {
        for c in 0..<4 {
            let i = 4 * c
            let a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3]
            s[i]     = AES128.mul(a0, 2) ^ AES128.mul(a1, 3) ^ a2 ^ a3
            s[i + 1] = a0 ^ AES128.mul(a1, 2) ^ AES128.mul(a2, 3) ^ a3
            s[i + 2] = a0 ^ a1 ^ AES128.mul(a2, 2) ^ AES128.mul(a3, 3)
            s[i + 3] = AES128.mul(a0, 3) ^ a1 ^ a2 ^ AES128.mul(a3, 2)
        }
    }
}
#endif
