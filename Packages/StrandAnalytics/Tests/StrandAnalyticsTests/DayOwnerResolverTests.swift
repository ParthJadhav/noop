import XCTest
@testable import StrandAnalytics

final class DayOwnerResolverTests: XCTestCase {
    func testActiveStrapOwnsDayItHasData() {
        let candidates = [
            DayOwnerResolver.Candidate(deviceId: "my-whoop", priority: 0, hasData: true),
            DayOwnerResolver.Candidate(deviceId: "oura", priority: 2, hasData: true),
        ]
        XCTAssertEqual(
            DayOwnerResolver.resolve(day: "2026-06-15", lockedOwner: nil, candidates: candidates),
            "my-whoop"
        )
    }

    func testImportOnlyFillsGap() {
        let candidates = [
            DayOwnerResolver.Candidate(deviceId: "my-whoop", priority: 0, hasData: false),
            DayOwnerResolver.Candidate(deviceId: "oura", priority: 2, hasData: true),
        ]
        XCTAssertEqual(
            DayOwnerResolver.resolve(day: "2026-06-15", lockedOwner: nil, candidates: candidates),
            "oura"
        )
    }

    func testLockedOwnerAlwaysWins() {
        let candidates = [
            DayOwnerResolver.Candidate(deviceId: "my-whoop", priority: 0, hasData: false),
            DayOwnerResolver.Candidate(deviceId: "oura", priority: 2, hasData: true),
        ]
        XCTAssertEqual(
            DayOwnerResolver.resolve(day: "2026-06-15", lockedOwner: "my-whoop", candidates: candidates),
            "my-whoop"
        )
    }

    func testNoDataYieldsNil() {
        let candidates = [
            DayOwnerResolver.Candidate(deviceId: "my-whoop", priority: 0, hasData: false),
        ]
        XCTAssertNil(
            DayOwnerResolver.resolve(day: "2026-06-15", lockedOwner: nil, candidates: candidates)
        )
    }
}
