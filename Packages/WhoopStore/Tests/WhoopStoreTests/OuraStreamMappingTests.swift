import XCTest
import WhoopProtocol
import OuraProtocol
@testable import WhoopStore

final class OuraStreamMappingTests: XCTestCase {
    private let ts = 1_750_000_000

    // MARK: - HR 0x55 -> hr:[HRSample]

    func testHRMapsToHRStreamStampedAtArrival() {
        let s = OuraStreamMapping.streams(from: [
            .hr(OuraHR(ringTimestamp: 100, bpm: 58, ibiMs: 1034)),
            .hr(OuraHR(ringTimestamp: 101, bpm: 60, ibiMs: 1000)),
        ], at: ts)
        XCTAssertEqual(s.hr.map { $0.bpm }, [58, 60])
        XCTAssertEqual(s.hr.map { $0.ts }, [ts, ts])
        // The HR push also carries one IBI, but RR comes only from .ibi events -> no double-count.
        XCTAssertTrue(s.rr.isEmpty)
    }

    // MARK: - IBI 0x44/0x60 -> rr:[RRInterval]

    func testIBIMapsToRRStream() {
        let s = OuraStreamMapping.streams(from: [
            .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 820)),
            .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 815, amplitude: 42)),
        ], at: ts)
        XCTAssertEqual(s.rr.map { $0.rrMs }, [820, 815])
        XCTAssertEqual(s.rr.map { $0.ts }, [ts, ts])
        XCTAssertTrue(s.hr.isEmpty)
    }

    // MARK: - HRV 0x5D -> events[OURA_HRV] with RAW, units-neutral payload (no fabricated rmssd_ms)

    func testHRVMapsToEventWithRawNeutralPayload() {
        let s = OuraStreamMapping.streams(from: [
            .hrv(OuraHRV(ringTimestamp: 100, timeMs: 5000, b1: 47, b2: 3)),
        ], at: ts)
        XCTAssertEqual(s.events.count, 1)
        let ev = s.events[0]
        XCTAssertEqual(ev.kind, OuraStreamMapping.hrvEventKind)
        XCTAssertEqual(ev.kind, "OURA_HRV")
        XCTAssertEqual(ev.ts, ts)
        // HONEST: the ring's OWN raw tag fields only; the b1/b2 byte -> ms scale is not Tier-A, so we
        // NEVER surface a fabricated rmssd_ms. Keys + values match the Kotlin twin exactly.
        XCTAssertNil(ev.payload["rmssd_ms"], "must not fabricate rmssd_ms")
        XCTAssertEqual(ev.payload["time_ms"], .int(5000))
        XCTAssertEqual(ev.payload["b1"], .int(47))
        XCTAssertEqual(ev.payload["b2"], .int(3))
    }

    // MARK: - SpO2 -> spo2:[SpO2Sample]

    func testSpO2MapsToSpO2StreamPreservingUnit() {
        let s = OuraStreamMapping.streams(from: [
            .spo2(OuraSpO2(ringTimestamp: 100, value: 970, unit: "raw")),
            .spo2(OuraSpO2(ringTimestamp: 101, value: 12345, unit: "dc_raw")),
        ], at: ts)
        XCTAssertEqual(s.spo2.map { $0.red }, [970, 12345])
        XCTAssertEqual(s.spo2.map { $0.ir }, [0, 0])
        XCTAssertEqual(s.spo2.map { $0.unit }, ["raw", "dc_raw"])
        XCTAssertEqual(s.spo2.map { $0.ts }, [ts, ts])
    }

    // MARK: - Temp 0x46/0x75 -> skinTemp:[SkinTempSample] (centi-degree-C, parity with Kotlin)

    func testTempMapsToSkinTempAsCentiC() {
        let s = OuraStreamMapping.streams(from: [
            .temp(OuraTemp(ringTimestamp: 100, celsius: 33.25)),
        ], at: ts)
        XCTAssertEqual(s.skinTemp.count, 1)
        // Centi-degree-C: the codebase-wide raw convention (AnalyticsEngine divides raw by 100).
        // 33.25 °C -> 3325. The Kotlin twin must produce the IDENTICAL raw integer for the same celsius.
        XCTAssertEqual(s.skinTemp[0].raw, 3325)
        XCTAssertEqual(s.skinTemp[0].unit, "centi_c")
        XCTAssertEqual(s.skinTemp[0].ts, ts)
    }

    // MARK: - Sleep phase -> events[OURA_SLEEP_PHASE]

    func testSleepPhaseMapsToEventWithPhaseCode() {
        let s = OuraStreamMapping.streams(from: [
            .sleepPhase(OuraSleepPhase(ringTimestamp: 100, index: 0, stage: .deep)),
            .sleepPhase(OuraSleepPhase(ringTimestamp: 100, index: 1, stage: .rem)),
        ], at: ts)
        XCTAssertEqual(s.events.count, 2)
        XCTAssertTrue(s.events.allSatisfy { $0.kind == OuraStreamMapping.sleepPhaseEventKind })
        XCTAssertEqual(s.events.map { $0.payload["phase"] }, [.int(2), .int(3)])
        XCTAssertEqual(s.events.map { $0.payload["index"] }, [.int(0), .int(1)])
        XCTAssertEqual(s.events.map { $0.ts }, [ts, ts])
    }

    // MARK: - Battery -> battery:[BatterySample]

    func testBatteryMapsToBatterySample() {
        let s = OuraStreamMapping.streams(from: [
            .battery(OuraBattery(percent: 74, voltageMv: 4012, charging: false)),
        ], at: ts)
        XCTAssertEqual(s.battery.count, 1)
        XCTAssertEqual(s.battery[0].soc, 74)
        XCTAssertEqual(s.battery[0].mv, 4012)
        XCTAssertEqual(s.battery[0].charging, false)
        XCTAssertEqual(s.battery[0].ts, ts)
    }

    func testBatteryWithoutVoltageOrChargingStaysNil() {
        let s = OuraStreamMapping.streams(from: [
            .battery(OuraBattery(percent: 50)),
        ], at: ts)
        XCTAssertEqual(s.battery[0].soc, 50)
        XCTAssertNil(s.battery[0].mv)
        XCTAssertNil(s.battery[0].charging)
    }

    // MARK: - Honest-data invariant: Tier-B + non-stream events never land in Streams

    func testTierBAndDiagnosticEventsAreDropped() {
        let s = OuraStreamMapping.streams(from: [
            .tierB(OuraTierBSummary(tag: 0x6A, ringTimestamp: 100, rawPayload: [1, 2, 3], kind: "sleep_summary")),
            .motion(OuraMotion(ringTimestamp: 100, index: 0, state: .active)),
            .state(OuraState(ringTimestamp: 100, stateCode: 1)),
            .timeSync(OuraTimeSync(ringTimestamp: 100, epochMs: 1_750_000_000_000, tzOffsetSeconds: 0)),
            .rtcBeacon(OuraRtcBeacon(ringTimestamp: 100, unixSeconds: 1_750_000_000)),
            .debugText(ringTimestamp: 100, text: "console"),
            // 0x50 activity/MET (PR #960): decoded but Tier-B/unvalidated - in particular it must never
            // mint a `steps` row (MET is not a step count; the per-source day-owner rules stay intact).
            .activityInfo(OuraActivityInfo(ringTimestamp: 100, state: 0x41, met: [1.8, 1.9])),
        ], at: ts)
        XCTAssertTrue(s.isEmpty, "Tier-B and diagnostic events must not produce any durable stream row")
        XCTAssertTrue(s.steps.isEmpty, "activity/MET must never fabricate a steps row")
    }

    // MARK: - Empty batch + multi-signal batch

    func testEmptyBatchYieldsEmptyStreams() {
        XCTAssertTrue(OuraStreamMapping.streams(from: [], at: ts).isEmpty)
    }

    func testMixedBatchPopulatesEachStreamIndependently() {
        let s = OuraStreamMapping.streams(from: [
            .hr(OuraHR(ringTimestamp: 1, bpm: 55, ibiMs: 1090)),
            .ibi(OuraIBI(ringTimestamp: 1, ibiMs: 1090)),
            .hrv(OuraHRV(ringTimestamp: 1, timeMs: 0, b1: 40, b2: 1)),
            .spo2(OuraSpO2(ringTimestamp: 1, value: 965)),
            .temp(OuraTemp(ringTimestamp: 1, celsius: 34.0)),
            .sleepPhase(OuraSleepPhase(ringTimestamp: 1, index: 0, stage: .light)),
            .battery(OuraBattery(percent: 88)),
        ], at: ts)
        XCTAssertEqual(s.hr.count, 1)
        XCTAssertEqual(s.rr.count, 1)
        XCTAssertEqual(s.spo2.count, 1)
        XCTAssertEqual(s.skinTemp.count, 1)
        XCTAssertEqual(s.battery.count, 1)
        // HRV + sleep-phase both ride the events stream.
        XCTAssertEqual(s.events.count, 2)
        // Streams never decoded by the Oura source stay empty (honest, never faked).
        XCTAssertTrue(s.resp.isEmpty)
        XCTAssertTrue(s.gravity.isEmpty)
        XCTAssertTrue(s.steps.isEmpty)
        XCTAssertTrue(s.ppgHr.isEmpty)
    }
}
