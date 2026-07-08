import XCTest
@testable import WhoopProtocol

/// Device-family-aware skin-temp raw→°C conversion (#938).
///
/// The historical `skin_temp_raw` register is on DIFFERENT scales per family: a CENTIDEGREE value on the
/// 5/MG v18 (@73) but a RAW ADC on the WHOOP 4.0 v24 (@72). A single family-blind `raw/100` sent every
/// 4.0 night ~8 °C low, below the 28 °C worn gate, so skin temp + the illness signal vanished (issue
/// #938, reporter dpguglielmi's 4.0 capture: worn steady raw ~826, no-contact floor ~510). These tests
/// pin the two scales so a regression that unifies them fails loudly.
final class SkinTempConversionTests: XCTestCase {

    // MARK: - WHOOP 5/MG (unchanged: raw/100 centidegrees)

    /// The proven 5/MG scale: the real Whoop5HistoricalTests captures read worn 3057 = 30.6 °C and
    /// off-wrist 2247 = 22.5 °C — physically right on both ends. This must NOT change.
    func testWhoop5IsUnchangedCentidegrees() {
        XCTAssertEqual(skinTempCelsius(raw: 3057, family: .whoop5), 30.57, accuracy: 1e-9)
        XCTAssertEqual(skinTempCelsius(raw: 2247, family: .whoop5), 22.47, accuracy: 1e-9)
        XCTAssertEqual(skinTempCelsius(raw: 3400, family: .whoop5), 34.0, accuracy: 1e-9)
    }

    // MARK: - WHOOP 4.0 v24 (raw ADC map)

    /// The reporter's steady WORN 4.0 baseline (raw ~826, worn steady ~830–865) must land in the plausible
    /// worn skin-temp band (28–42 °C) — the whole point of the fix. Under the OLD /100 scale these read
    /// ~8.3 °C and every 4.0 night was dropped.
    func testWhoop4WornBaselineLandsInPlausibleBand() {
        for raw in [826, 830, 845, 859, 865] {
            let c = skinTempCelsius(raw: raw, family: .whoop4)
            XCTAssertGreaterThanOrEqual(c, 28.0, "worn 4.0 raw \(raw) → \(c) °C must clear the 28 °C worn gate")
            XCTAssertLessThanOrEqual(c, 42.0, "worn 4.0 raw \(raw) → \(c) °C must stay under the 42 °C worn ceiling")
        }
        // The anchor itself is the pinned worn skin temperature.
        XCTAssertEqual(skinTempCelsius(raw: 826, family: .whoop4), 33.0, accuracy: 1e-9)
    }

    /// The no-contact floor (raw ~510–520, seen at doff) is NOT a worn value; it must read BELOW the 28 °C
    /// worn gate so it is excluded from the nightly mean rather than poisoning it.
    func testWhoop4NoContactFloorIsBelowWornGate() {
        for raw in [506, 514, 520] {
            XCTAssertLessThan(skinTempCelsius(raw: raw, family: .whoop4), 28.0,
                              "4.0 no-contact floor raw \(raw) must fall below the worn gate")
        }
    }

    /// The 4.0 scale is DIFFERENT from the 5/MG scale for the same register value — a regression that reuses
    /// /100 for a 4.0 would collapse these to equal and fail here.
    func testWhoop4AndWhoop5DifferForTheSameRaw() {
        XCTAssertNotEqual(skinTempCelsius(raw: 826, family: .whoop4),
                          skinTempCelsius(raw: 826, family: .whoop5), accuracy: 1e-6)
    }

    /// The synthetic HistoricalV24Tests fixture banks skin_temp_raw = 900; under the family-aware map it is a
    /// plausible worn reading (was an impossible 9 °C under the old /100).
    func testWhoop4SyntheticFixtureRawIsPlausible() {
        let c = skinTempCelsius(raw: 900, family: .whoop4)
        XCTAssertGreaterThan(c, 28.0)
        XCTAssertLessThan(c, 42.0)
    }
}
