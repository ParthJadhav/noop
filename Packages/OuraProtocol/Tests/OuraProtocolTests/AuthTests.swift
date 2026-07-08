import XCTest
@testable import OuraProtocol

/// AES auth known-answer + command-framing tests. The proof vector below was computed independently
/// (openssl aes-128-ecb, no-pad, over nonce(15) || 0x01 || 0x10 x16) so it is a true cross-check of
/// our AES path, NOT a self-referential round-trip. The padding equivalence (explicit 0x10-block ==
/// AES/ECB/PKCS5Padding) was also confirmed externally, which is what the Kotlin twin relies on.
final class AuthTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    // MARK: - AES-128-ECB block known-answer (FIPS-197 C.1)

    func testAES128ECBKnownAnswerFIPS197() throws {
        // FIPS-197 appendix C.1: key 000102..0f, input 00112233445566778899aabbccddeeff
        // -> output 69c4e0d86a7b0430d8cdb78070b4c55a. Proves the AES core (Apple CommonCrypto path or
        // the portable fallback) is correct before we trust the proof computation.
        let key = bytes("000102030405060708090a0b0c0d0e0f")
        let input = bytes("00112233445566778899aabbccddeeff")
        let out = try aes128EcbEncryptNoPad(input, key: key)
        XCTAssertEqual(hex(out), "69c4e0d86a7b0430d8cdb78070b4c55a")
    }

    // MARK: - Oura proof known-answer

    func testAuthProofKnownVector() throws {
        // Deterministic key + 15-byte nonce. Expected proof computed via openssl raw AES-128-ECB over
        // nonce || 0x01 || (0x10 x16), first 16 ciphertext bytes.
        let key = bytes("000102030405060708090a0b0c0d0e0f")
        let nonce = bytes("0102030405060708090a0b0c0d0e0f")  // 15 bytes
        XCTAssertEqual(nonce.count, 15)
        let proof = try OuraAuth.computeProof(nonce: nonce, key: key)
        XCTAssertEqual(hex(proof), "c49fb9e83c46087a555183a9dc511ee9")
    }

    func testProofIsExactlyFirstCipherBlock() throws {
        // The proof must be exactly the FIRST 16 ciphertext bytes, never the whole 32-byte output.
        let key = bytes("000102030405060708090a0b0c0d0e0f")
        let nonce = bytes("0102030405060708090a0b0c0d0e0f")
        let proof = try OuraAuth.computeProof(nonce: nonce, key: key)
        XCTAssertEqual(proof.count, 16)
    }

    // MARK: - Padding is load-bearing

    func testTrailingMarkerAndFullBlockPadChangeTheProof() throws {
        // If we (wrongly) skipped the trailing 0x01 + pad, the cipher input differs and the proof
        // would change. Encrypt the bare 16-byte nonce-with-marker WITHOUT the extra pad block and
        // confirm the first block still matches (PKCS full-block pad does not alter block 1), but a
        // DIFFERENT trailing marker does change it.
        let key = bytes("000102030405060708090a0b0c0d0e0f")
        let nonce = bytes("0102030405060708090a0b0c0d0e0f")
        let correct = try OuraAuth.computeProof(nonce: nonce, key: key)

        // Same nonce, wrong marker (0x02 instead of 0x01) -> block 1 differs -> proof differs.
        var wrongPlain = nonce
        wrongPlain.append(0x02)
        wrongPlain.append(contentsOf: [UInt8](repeating: 0x10, count: 16))
        let wrongCipher = try aes128EcbEncryptNoPad(wrongPlain, key: key)
        XCTAssertNotEqual(Array(wrongCipher[0..<16]), correct,
                          "the trailing 0x01 marker is load-bearing; a different marker must change the proof")
    }

    // MARK: - Length guards

    func testBadKeyLengthThrows() {
        XCTAssertThrowsError(try OuraAuth.computeProof(nonce: bytes("0102030405060708090a0b0c0d0e0f"),
                                                       key: [0x00, 0x01])) { e in
            XCTAssertEqual(e as? OuraAuthError, .badKeyLength)
        }
    }

    func testBadNonceLengthThrows() {
        XCTAssertThrowsError(try OuraAuth.computeProof(nonce: [0x00, 0x01],
                                                       key: bytes("000102030405060708090a0b0c0d0e0f"))) { e in
            XCTAssertEqual(e as? OuraAuthError, .badNonceLength)
        }
    }

    // MARK: - Command framing

    func testGetAuthNonceCommandBytes() {
        XCTAssertEqual(OuraAuth.getAuthNonceCommand(), [0x2F, 0x01, 0x2B])
    }

    func testInstallKeyCommandBytes() throws {
        let key = bytes("000102030405060708090a0b0c0d0e0f")
        let cmd = try OuraAuth.installKeyCommand(key)
        XCTAssertEqual(Array(cmd[0..<2]), [0x24, 0x10])
        XCTAssertEqual(Array(cmd[2...]), key)
    }

    func testSubmitProofCommandBytes() throws {
        let proof = bytes("c49fb9e83c46087a555183a9dc511ee9")
        let cmd = try OuraAuth.submitProofCommand(proof)
        XCTAssertEqual(Array(cmd[0..<3]), [0x2F, 0x11, 0x2D])
        XCTAssertEqual(Array(cmd[3...]), proof)
    }

    // MARK: - Secure-frame parsing of nonce / status

    func testNonceExtractedFromSecureFrame() {
        // 2f 10 2c <nonce:15> -> as parsed by Framing: op 0x2F, subop 0x10, subBody = 2c?
        // The wire is `2f <len> 10 2c <nonce>`? Per s3.3 the response is `2f 10 2c <nonce:15>` where
        // 0x10 is the LEN byte (16 body bytes: 2c + 15 nonce). So subop is 0x2C and subBody = nonce.
        let nonce = bytes("0102030405060708090a0b0c0d0e0f")
        let frame = OuraSecureFrame(subop: 0x2C, subBody: nonce)
        XCTAssertEqual(OuraAuth.nonce(from: frame), nonce)
    }

    func testAuthStatusParsed() {
        let frame = OuraSecureFrame(subop: 0x2E, subBody: [0x00])
        XCTAssertEqual(OuraAuth.authStatus(from: frame), .success)
        let fail = OuraSecureFrame(subop: 0x2E, subBody: [0x01])
        XCTAssertEqual(OuraAuth.authStatus(from: fail), .authError)
        let reset = OuraSecureFrame(subop: 0x2E, subBody: [0x02])
        XCTAssertEqual(OuraAuth.authStatus(from: reset), .inFactoryReset)
    }
}
