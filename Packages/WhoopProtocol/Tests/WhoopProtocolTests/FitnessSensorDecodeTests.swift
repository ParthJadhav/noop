import XCTest
@testable import WhoopProtocol

/// Spec-deterministic decode contract for the three standard fitness-sensor profiles NOOP reads live
/// alongside HR — RSC (0x2A53), CSC (0x2A5B), CPS (0x2A63). Fixtures are built BYTE-BY-BYTE from the
/// Bluetooth SIG service specs (not real captures), so each asserts the exact flag→field mapping and the
/// fixed-point→unit scaling. The cumulative-counter profiles (CSC/CPS) additionally test the pure
/// `FitnessRateComputer` derivation, including the first-packet-yields-nil honesty guard and clock wrap.
/// Pure decode → headless `swift test`, exactly like FTMSDecodeTests.
final class FitnessSensorDecodeTests: XCTestCase {

    private func bytes(_ v: [Int]) -> [UInt8] { v.map { UInt8($0 & 0xFF) } }
    private func le16(_ v: Int) -> [Int] { [v & 0xFF, (v >> 8) & 0xFF] }
    private func le32(_ v: Int) -> [Int] { [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF] }

    // MARK: - Running Speed and Cadence (0x2A53)

    func testRSCSpeedAndCadenceAlwaysPresent() {
        // flags 0x00: no stride, no distance, walking. Speed 1/256 m/s, cadence steps/min.
        let p = [0x00] + le16(768) + [170]      // 768/256 = 3.0 m/s; cadence 170 spm
        let r = FitnessSensorDecode.runningSpeedCadence(bytes(p))!
        XCTAssertEqual(r.kind, .runningSpeedCadence)
        XCTAssertEqual(r.speedMps!, 3.0, accuracy: 0.0001)
        XCTAssertEqual(r.runningCadenceSpm, 170)
        XCTAssertEqual(r.isRunning, false)
        XCTAssertEqual(r.speedKmh!, 10.8, accuracy: 0.0001)   // 3.0 m/s = 10.8 km/h
        XCTAssertNil(r.totalDistanceM)
    }

    func testRSCRunningFlagAndTotalDistanceWithStrideSkipped() {
        // flags: stride present (bit0), total distance present (bit1), running (bit2) → 0x07.
        // Stride must be SKIPPED by its 2-byte width or the u32 distance misreads.
        let p = [0x07] + le16(1024) + [88]      // 4.0 m/s, cadence 88
            + le16(0x0190)                       // stride length (skipped)
            + le32(54321)                        // total distance raw → /10 = 5432.1 m
        let r = FitnessSensorDecode.runningSpeedCadence(bytes(p))!
        XCTAssertEqual(r.speedMps!, 4.0, accuracy: 0.0001)
        XCTAssertEqual(r.runningCadenceSpm, 88)
        XCTAssertEqual(r.isRunning, true)
        XCTAssertEqual(r.totalDistanceM!, 5432.1, accuracy: 0.0001)
    }

    // MARK: - Cycling Speed and Cadence (0x2A5B)

    func testCSCWheelAndCrankRawFields() {
        // flags: wheel (bit0) + crank (bit1) → 0x03.
        let p = [0x03] + le32(100) + le16(2048) + le16(50) + le16(1024)
        let r = FitnessSensorDecode.cyclingSpeedCadence(bytes(p))!
        XCTAssertEqual(r.kind, .cyclingSpeedCadence)
        XCTAssertEqual(r.cumulativeWheelRevolutions, 100)
        XCTAssertEqual(r.lastWheelEventTime1024, 2048)
        XCTAssertEqual(r.cumulativeCrankRevolutions, 50)
        XCTAssertEqual(r.lastCrankEventTime1024, 1024)
        // A raw decode carries no instantaneous values — those are derived by the rate computer.
        XCTAssertNil(r.speedMps)
    }

    func testCSCCrankOnlyOmitsWheel() {
        // flags: crank only (bit1) → 0x02. Wheel block ABSENT; crank decoded directly after flags.
        let p = [0x02] + le16(77) + le16(4096)
        let r = FitnessSensorDecode.cyclingSpeedCadence(bytes(p))!
        XCTAssertNil(r.cumulativeWheelRevolutions)
        XCTAssertEqual(r.cumulativeCrankRevolutions, 77)
        XCTAssertEqual(r.lastCrankEventTime1024, 4096)
    }

    // MARK: - Cycling Power Measurement (0x2A63)

    func testCPSInstantaneousPowerAlwaysPresent() {
        // flags 0x0000: only the mandatory instantaneous power follows.
        let p = le16(0x0000) + le16(243)
        let r = FitnessSensorDecode.cyclingPower(bytes(p))!
        XCTAssertEqual(r.kind, .cyclingPower)
        XCTAssertEqual(r.instantaneousPowerWatts, 243)
    }

    func testCPSNegativePowerIsSigned() {
        // sint16 0xFFFF = -1 W (a freewheel/coast reading the spec permits).
        let r = FitnessSensorDecode.cyclingPower(bytes(le16(0x0000) + le16(0xFFFF)))!
        XCTAssertEqual(r.instantaneousPowerWatts, -1)
    }

    func testCPSCrankDataAfterSkippedOptionalsDecodesCleanly() {
        // flags: Pedal Power Balance (bit0, u8) + Accumulated Torque (bit2, u16) + Crank Data (bit5).
        // The two optional fields must be skipped by the right widths or the crank block misreads.
        let flags = 0x0001 | 0x0004 | 0x0020
        let p = le16(flags) + le16(200)         // power 200 W
            + [60]                               // pedal power balance (skip)
            + le16(0x1234)                       // accumulated torque (skip)
            + le16(42) + le16(8192)              // crank revs 42, last crank event 8192
        let r = FitnessSensorDecode.cyclingPower(bytes(p))!
        XCTAssertEqual(r.instantaneousPowerWatts, 200)
        XCTAssertEqual(r.cumulativeCrankRevolutions, 42)
        XCTAssertEqual(r.lastCrankEventTime1024, 8192)
    }

    func testCPSWheelDataDerivesSpeed() {
        // flags: Wheel Revolution Data (bit4) → cumulative wheel + last wheel event.
        let p = le16(0x0010) + le16(180) + le32(500) + le16(1000)
        let r = FitnessSensorDecode.cyclingPower(bytes(p))!
        XCTAssertEqual(r.instantaneousPowerWatts, 180)
        XCTAssertEqual(r.cumulativeWheelRevolutions, 500)
        XCTAssertEqual(r.lastWheelEventTime1024, 1000)
    }

    // MARK: - Rate computer (HONEST derivation)

    func testRateComputerFirstPacketYieldsNil() {
        var rc = FitnessRateComputer(wheelCircumferenceM: 2.0)
        let first = FitnessSensorReading(kind: .cyclingSpeedCadence,
                                         cumulativeWheelRevolutions: 100, lastWheelEventTime1024: 1024,
                                         cumulativeCrankRevolutions: 10, lastCrankEventTime1024: 1024)
        let r = rc.update(first)
        XCTAssertNil(r.speedMps)     // nothing to diff against → no fabricated rate
        XCTAssertNil(r.crankRpm)
    }

    func testRateComputerDerivesSpeedAndCadenceFromTwoPackets() {
        var rc = FitnessRateComputer(wheelCircumferenceM: 2.0)
        _ = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                           cumulativeWheelRevolutions: 100, lastWheelEventTime1024: 1024,
                                           cumulativeCrankRevolutions: 10, lastCrankEventTime1024: 1024))
        // Exactly 1 second later (1024 ticks): +5 wheel revs, +1 crank rev.
        let r = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                               cumulativeWheelRevolutions: 105, lastWheelEventTime1024: 2048,
                                               cumulativeCrankRevolutions: 11, lastCrankEventTime1024: 2048))
        // 5 revs × 2.0 m over 1 s = 10 m/s.
        XCTAssertEqual(r.speedMps!, 10.0, accuracy: 0.0001)
        XCTAssertEqual(r.speedKmh!, 36.0, accuracy: 0.0001)
        // 1 crank rev over 1 s = 60 rpm.
        XCTAssertEqual(r.crankRpm!, 60.0, accuracy: 0.0001)
    }

    // MARK: - CPS wheel tick rate (PR #1007: 0x2A63 wheel event time is 1/2048 s, NOT 1/1024 s)

    func testRateComputerCPSWheelEventTimeTicksAt2048() {
        // Real CPS timestamps → exact speed pin. 4096 ticks at 1/2048 s = 2 s (a /1024 bug would read
        // 4 s and halve this). +5 revs × 2.0 m over 2 s = 5 m/s.
        var rc = FitnessRateComputer(wheelCircumferenceM: 2.0)
        _ = rc.update(FitnessSensorReading(kind: .cyclingPower,
                                           cumulativeWheelRevolutions: 100, lastWheelEventTime1024: 2048))
        let r = rc.update(FitnessSensorReading(kind: .cyclingPower,
                                               cumulativeWheelRevolutions: 105, lastWheelEventTime1024: 6144))
        XCTAssertEqual(r.speedMps!, 5.0, accuracy: 0.0001)
        XCTAssertEqual(r.speedKmh!, 18.0, accuracy: 0.0001)
    }

    func testRateComputerCPSWheelDerivesDoubleTheCSCSpeedForIdenticalBytes() {
        // Regression pin for the halved-speed bug: byte-identical counters/timestamps to the CSC
        // two-packet test above (1024-tick delta, +5 revs, 2.0 m wheel) must derive DOUBLE the speed on
        // a CPS source — 1024 ticks span 0.5 s at 1/2048 s, not 1 s. CSC on the same numbers pins 10 m/s.
        var rc = FitnessRateComputer(wheelCircumferenceM: 2.0)
        _ = rc.update(FitnessSensorReading(kind: .cyclingPower,
                                           cumulativeWheelRevolutions: 100, lastWheelEventTime1024: 1024))
        let r = rc.update(FitnessSensorReading(kind: .cyclingPower,
                                               cumulativeWheelRevolutions: 105, lastWheelEventTime1024: 2048))
        XCTAssertEqual(r.speedMps!, 20.0, accuracy: 0.0001)
        XCTAssertEqual(r.speedKmh!, 72.0, accuracy: 0.0001)
    }

    func testRateComputerCPSCrankStaysAt1024() {
        // Guard against over-correcting: CPS CRANK event time is 1/1024 s (same as CSC) — only the wheel
        // clock differs. +1 crank rev over 1024 ticks = 1 s = 60 rpm, NOT 120.
        var rc = FitnessRateComputer()
        _ = rc.update(FitnessSensorReading(kind: .cyclingPower,
                                           cumulativeCrankRevolutions: 10, lastCrankEventTime1024: 1024))
        let r = rc.update(FitnessSensorReading(kind: .cyclingPower,
                                               cumulativeCrankRevolutions: 11, lastCrankEventTime1024: 2048))
        XCTAssertEqual(r.crankRpm!, 60.0, accuracy: 0.0001)
    }

    func testRateComputerWheelKindFlipYieldsNilThenReseeds() {
        // A 2A5B↔2A63 flip means the baseline timestamp is on a DIFFERENT clock base (1/1024 vs 1/2048 s)
        // — a cross-base delta would fabricate a speed, so the first post-flip packet must yield nil and
        // re-seed the baseline. The packet AFTER that derives normally on the new base.
        var rc = FitnessRateComputer(wheelCircumferenceM: 2.0)
        _ = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                           cumulativeWheelRevolutions: 100, lastWheelEventTime1024: 1024))
        let flip = rc.update(FitnessSensorReading(kind: .cyclingPower,
                                                  cumulativeWheelRevolutions: 105, lastWheelEventTime1024: 2048))
        XCTAssertNil(flip.speedMps)   // never a speed computed across mixed clocks
        let settled = rc.update(FitnessSensorReading(kind: .cyclingPower,
                                                     cumulativeWheelRevolutions: 110, lastWheelEventTime1024: 4096))
        XCTAssertEqual(settled.speedMps!, 10.0, accuracy: 0.0001)   // 5 revs × 2 m over 2048/2048 = 1 s
        // Flip back the other way: same rule, nil again.
        let flipBack = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                                      cumulativeWheelRevolutions: 115, lastWheelEventTime1024: 5120))
        XCTAssertNil(flipBack.speedMps)
    }

    func testRateComputerNoNewRevolutionYieldsNil() {
        var rc = FitnessRateComputer()
        _ = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                           cumulativeCrankRevolutions: 50, lastCrankEventTime1024: 1000))
        // Same event time (coasting / stopped) → no time has passed → no rate, not a divide-by-zero.
        let r = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                               cumulativeCrankRevolutions: 50, lastCrankEventTime1024: 1000))
        XCTAssertNil(r.crankRpm)
    }

    func testRateComputerHandlesEventTimeWrap() {
        var rc = FitnessRateComputer(wheelCircumferenceM: 2.0)
        // Last event near the top of the 16-bit 1/1024-s clock.
        _ = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                           cumulativeWheelRevolutions: 1000, lastWheelEventTime1024: 65000))
        // Wraps past 65536: 65000 → 488 is (65536-65000)+488 = 1024 ticks (1 s); +5 revs.
        let r = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                               cumulativeWheelRevolutions: 1005, lastWheelEventTime1024: 488))
        XCTAssertEqual(r.speedMps!, 10.0, accuracy: 0.0001)   // wrap handled, not a huge negative dt
    }

    func testRateComputerHandlesCrankCounterWrap() {
        var rc = FitnessRateComputer()
        _ = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                           cumulativeCrankRevolutions: 65534, lastCrankEventTime1024: 1024))
        // u16 crank counter wraps 65534 → 1 = +3 revs over 1 s = 180 rpm.
        let r = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                               cumulativeCrankRevolutions: 1, lastCrankEventTime1024: 2048))
        XCTAssertEqual(r.crankRpm!, 180.0, accuracy: 0.0001)
    }

    func testRateComputerResetClearsBaseline() {
        var rc = FitnessRateComputer(wheelCircumferenceM: 2.0)
        _ = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                           cumulativeWheelRevolutions: 100, lastWheelEventTime1024: 1024))
        rc.reset()
        // After reset the next packet is a first packet again → nil, no carry-over from the old baseline.
        let r = rc.update(FitnessSensorReading(kind: .cyclingSpeedCadence,
                                               cumulativeWheelRevolutions: 200, lastWheelEventTime1024: 2048))
        XCTAssertNil(r.speedMps)
    }

    // MARK: - Robustness over UNTRUSTED / malformed input

    func testEmptyAndShortBuffersNeverCrash() {
        XCTAssertNil(FitnessSensorDecode.runningSpeedCadence([]))
        XCTAssertNil(FitnessSensorDecode.cyclingSpeedCadence([]))
        XCTAssertNil(FitnessSensorDecode.cyclingPower([0x00]))      // flags need 2 bytes
        // RSC flags present but the mandatory speed is truncated to one byte → speed not consumed, no crash.
        let r = FitnessSensorDecode.runningSpeedCadence(bytes([0x00, 0x10]))
        XCTAssertNotNil(r)
        XCTAssertNil(r!.speedMps)
    }

    func testHugeBufferIsBounded() {
        // CPS with only mandatory power declared, then 5 KB of junk — must read power and ignore the tail.
        var p = le16(0x0000) + le16(321)
        p += Array(repeating: 0xAB, count: 5000)
        let r = FitnessSensorDecode.cyclingPower(bytes(p))!
        XCTAssertEqual(r.instantaneousPowerWatts, 321)
    }

    func testDecodeByUUIDDispatch() {
        XCTAssertEqual(FitnessSensorDecode.decode(uuid16: "2a53", bytes([0x00] + le16(256) + [60]))?.kind,
                       .runningSpeedCadence)
        XCTAssertEqual(FitnessSensorDecode.decode(uuid16: "2A5B", bytes([0x02] + le16(1) + le16(1)))?.kind,
                       .cyclingSpeedCadence)
        XCTAssertEqual(FitnessSensorDecode.decode(uuid16: "2A63", bytes(le16(0) + le16(0)))?.kind,
                       .cyclingPower)
        XCTAssertNil(FitnessSensorDecode.decode(uuid16: "1234", [0x00, 0x00]))
    }
}
