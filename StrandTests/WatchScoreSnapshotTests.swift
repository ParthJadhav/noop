import XCTest
import StrandDesign
@testable import Strand

/// Pins the phone to watch payload's wire contract (M3). `WatchScoreSnapshot` is the one shared Codable
/// type the iOS `WatchSessionBridge` encodes and the watchOS app + complication decode, so its round
/// trip has to be exact. The honesty rule is the load-bearing assertion: a calibrating score MUST stay
/// `nil` + its flag true through encode/decode, so the watch can never render a fabricated number.
///
/// Pure value-type round trip, runs on macOS with no device, no WatchConnectivity.
final class WatchScoreSnapshotTests: XCTestCase {

    func testFullSnapshotRoundTrips() throws {
        let asOf = Date(timeIntervalSince1970: 1_700_000_000)
        let original = WatchScoreSnapshot(
            charge: 72,
            chargeCalibrating: false,
            effort: 8.5,
            effortCalibrating: false,
            rest: 81,
            restCalibrating: false,
            hr: 58,
            sleepSummary: "7h 12m · 81%",
            asOf: asOf
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WatchScoreSnapshot.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.charge, 72)
        XCTAssertEqual(decoded.effort, 8.5)
        XCTAssertEqual(decoded.rest, 81)
        XCTAssertEqual(decoded.hr, 58)
        XCTAssertEqual(decoded.sleepSummary, "7h 12m · 81%")
        XCTAssertEqual(decoded.asOf, asOf)
        XCTAssertFalse(decoded.chargeCalibrating)
        XCTAssertFalse(decoded.effortCalibrating)
        XCTAssertFalse(decoded.restCalibrating)
    }

    func testCalibratingScoreStaysNilAndFlagged() throws {
        // The honesty rule: a calibrating score is the number being nil AND the flag true. It must
        // survive the round trip as exactly that, never a fabricated number. Charge is mid-calibration
        // here; Effort + Rest carry real numbers, so they stay un-flagged.
        let original = WatchScoreSnapshot(
            charge: nil,
            chargeCalibrating: true,
            effort: 6,
            effortCalibrating: false,
            rest: 77,
            restCalibrating: false,
            hr: nil,
            sleepSummary: "",
            asOf: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WatchScoreSnapshot.self, from: data)

        XCTAssertEqual(decoded, original)
        // The calibrating score: nil number, flag true.
        XCTAssertNil(decoded.charge)
        XCTAssertTrue(decoded.chargeCalibrating)
        // The earned scores survive intact and stay un-flagged.
        XCTAssertEqual(decoded.effort, 6)
        XCTAssertFalse(decoded.effortCalibrating)
        XCTAssertEqual(decoded.rest, 77)
        XCTAssertFalse(decoded.restCalibrating)
        // A missing HR is just absent.
        XCTAssertNil(decoded.hr)
    }

    func testAppGroupSaveLoadRoundTrips() throws {
        // The watch app + complication read the latest snapshot from the shared app group's
        // UserDefaults under `latestWatchSnapshot`. Exercise that path against an isolated suite so the
        // test never touches the real group.
        let suiteName = "test.watchScoreSnapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(WatchScoreSnapshot.load(from: defaults), "empty suite has no snapshot")

        let snap = WatchScoreSnapshot(
            charge: 64, chargeCalibrating: false,
            effort: nil, effortCalibrating: true,
            rest: nil, restCalibrating: true,
            hr: 61, sleepSummary: "6h 40m · 88%",
            asOf: Date(timeIntervalSince1970: 1_700_000_500)
        )
        snap.save(to: defaults)

        let loaded = try XCTUnwrap(WatchScoreSnapshot.load(from: defaults))
        XCTAssertEqual(loaded, snap)
        // The calibrating Effort + Rest survive the app-group round trip nil + flagged.
        XCTAssertNil(loaded.effort)
        XCTAssertTrue(loaded.effortCalibrating)
        XCTAssertNil(loaded.rest)
        XCTAssertTrue(loaded.restCalibrating)
    }

    func testStorageContractMatchesWatchSideExpectation() {
        // The cross-lane contract: app group + key are fixed strings both sides hard-agree on.
        XCTAssertEqual(WatchScoreSnapshot.appGroupId, "group.com.noopapp.noop")
        XCTAssertEqual(WatchScoreSnapshot.storageKey, "latestWatchSnapshot")
    }
}
