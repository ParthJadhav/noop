import XCTest
@testable import WhoopProtocol

/// GOLDEN DECODER ORACLE (lane-4 A8) , the Swift half of a shared Swift<->Kotlin drift guard.
///
/// `Resources/decoder_oracle.json` is a fixture of REAL captured WHOOP type-47 HISTORICAL_DATA frames
/// plus their expected decode. The IDENTICAL file is committed at
/// `android/app/src/test/resources/decoder_oracle.json`, and `DecoderOracleTest.kt` runs the same
/// assertions through the Kotlin `decodeHistorical`. Because both decoders are independent
/// reimplementations of the same byte layout, decoding the same fixture and asserting the same output
/// is what catches a one-sided edit (a moved offset / changed scaling on one platform only).
///
/// The fixture was seeded from existing in-repo test vectors (Whoop4HistoricalV24HardwareTests,
/// Whoop4HistoricalV25Tests, Whoop5HistoricalTests and their Kotlin twins), so every expected value is
/// already independently grounded , this test only proves the two decoders agree on it.
final class DecoderOracleTests: XCTestCase {

    // Mirrors the JSON shape. `expect` is a heterogeneous map decoded leniently below.
    private struct Oracle: Decodable {
        let tolerance: Double
        let frames: [Frame]
    }
    private struct Frame: Decodable {
        let name: String
        let family: String
        let hex: String
        let expect: [String: ExpectValue]
    }
    /// One expected field: an int, a double, or an int array. The JSON uses bare numbers; we accept
    /// either an Int or a Double for a numeric field so `1.0` and `1` both decode.
    private enum ExpectValue: Decodable {
        case int(Int)
        case double(Double)
        case intArray([Int])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let a = try? c.decode([Int].self) { self = .intArray(a); return }
            if let i = try? c.decode(Int.self) { self = .int(i); return }
            if let d = try? c.decode(Double.self) { self = .double(d); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unhandled expect value")
        }
    }

    private func hexToBytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    private func loadOracle() throws -> Oracle {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoder_oracle", withExtension: "json"),
                                "missing decoder_oracle.json test resource")
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    /// Each fixture frame decodes to the expected fields. ints exact, doubles within `tolerance`,
    /// gravity asserted by magnitude (`gravity_mag`) since the components are family-specific.
    func testOracleFramesDecodeToExpectedOutput() throws {
        let oracle = try loadOracle()
        XCTAssertGreaterThan(oracle.frames.count, 0, "no oracle frames loaded")

        for frame in oracle.frames {
            let family: DeviceFamily = frame.family == "whoop5" ? .whoop5 : .whoop4
            let parsed = parseFrame(hexToBytes(frame.hex), family: family).parsed

            for (key, expected) in frame.expect {
                switch key {
                case "gravity_mag":
                    // A whole-number magnitude like 1.0 decodes as .int(1) here, because OracleValue tries
                    // Int before Double and Foundation's JSONDecoder accepts `1.0` as Int — so accept both
                    // forms (an integer magnitude is still a valid double).
                    let wantMag: Double
                    switch expected {
                    case .double(let d): wantMag = d
                    case .int(let i): wantMag = Double(i)
                    default: XCTFail("gravity_mag must be a number in \(frame.name)"); continue
                    }
                    let gx = parsed["gravity_x"]?.doubleValue
                    let gy = parsed["gravity_y"]?.doubleValue
                    let gz = parsed["gravity_z"]?.doubleValue
                    XCTAssertNotNil(gx, "\(frame.name): gravity did not decode")
                    let mag = ((gx ?? 0) * (gx ?? 0) + (gy ?? 0) * (gy ?? 0) + (gz ?? 0) * (gz ?? 0)).squareRoot()
                    XCTAssertEqual(mag, wantMag, accuracy: 0.1, "\(frame.name): |gravity|")
                default:
                    switch expected {
                    case .int(let want):
                        XCTAssertEqual(parsed[key]?.intValue, want, "\(frame.name).\(key)")
                    case .intArray(let want):
                        XCTAssertEqual(parsed[key]?.intArrayValue ?? [], want, "\(frame.name).\(key)")
                    case .double(let want):
                        let got = try XCTUnwrap(parsed[key]?.doubleValue, "\(frame.name).\(key) missing")
                        XCTAssertEqual(got, want, accuracy: oracle.tolerance, "\(frame.name).\(key)")
                    }
                }
            }
        }
    }

    /// The Swift and Android copies of the oracle MUST be byte-identical, so neither platform can edit
    /// its fixture without the other. Compares the bundled Swift resource against the Android source
    /// copy (located relative to this test file). Skips gracefully if the Android tree isn't present
    /// (e.g. a Swift-only checkout) rather than failing for the wrong reason.
    func testOracleCopiesAreIdentical() throws {
        let swiftURL = try XCTUnwrap(Bundle.module.url(forResource: "decoder_oracle", withExtension: "json"))
        let swiftData = try Data(contentsOf: swiftURL)

        // .../Packages/WhoopProtocol/Tests/WhoopProtocolTests/DecoderOracleTests.swift -> repo root
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()  // WhoopProtocolTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // WhoopProtocol
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
        let androidURL = repoRoot
            .appendingPathComponent("android/app/src/test/resources/decoder_oracle.json")

        guard FileManager.default.fileExists(atPath: androidURL.path) else {
            throw XCTSkip("android oracle copy not present at \(androidURL.path)")
        }
        let androidData = try Data(contentsOf: androidURL)
        XCTAssertEqual(swiftData, androidData,
                       "decoder_oracle.json copies differ , keep the Swift and Android copies in lockstep")
    }
}
