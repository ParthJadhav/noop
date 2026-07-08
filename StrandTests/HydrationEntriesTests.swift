import XCTest
@testable import Strand

/// #798 - the per-entry hydration list (add / delete / edit / total). The day total banked into
/// `metricSeries` is always re-derived from this list, so the math here is the source of truth for an
/// edited day. These pin: a non-positive amount never enters the list, deleting/editing keeps the total
/// non-negative and self-consistent, and an edit to 0 is a delete (no zero rows linger).
final class HydrationEntriesTests: XCTestCase {

    private func entry(_ ml: Int, secondsAgo: TimeInterval = 0) -> HydrationEntry {
        HydrationEntry(amountMl: ml, loggedAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo))
    }

    // MARK: - adding

    func testAddingAppendsPositiveAmount() {
        let out = HydrationEntries.adding([], amountMl: 237)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.amountMl, 237)
    }

    func testAddingRejectsNonPositive() {
        XCTAssertTrue(HydrationEntries.adding([], amountMl: 0).isEmpty)
        XCTAssertTrue(HydrationEntries.adding([], amountMl: -50).isEmpty)
    }

    // MARK: - total

    func testTotalSumsAmounts() {
        let list = [entry(30), entry(237), entry(500)]
        XCTAssertEqual(HydrationEntries.total(list), 767, accuracy: 0.0001)
    }

    func testTotalOfEmptyIsZero() {
        XCTAssertEqual(HydrationEntries.total([]), 0, accuracy: 0.0001)
    }

    // MARK: - removing

    func testRemovingDropsTheTargetAndRederivesTotal() {
        let a = entry(30), b = entry(500)
        let after = HydrationEntries.removing([a, b], id: a.id)
        XCTAssertEqual(after.map(\.id), [b.id])
        XCTAssertEqual(HydrationEntries.total(after), 500, accuracy: 0.0001)
    }

    func testRemovingUnknownIdIsNoOp() {
        let a = entry(30)
        let after = HydrationEntries.removing([a], id: UUID())
        XCTAssertEqual(after.map(\.id), [a.id])
    }

    // MARK: - updating

    func testUpdatingSetsNewAmountAndKeepsIdentity() {
        let a = entry(30)
        let after = HydrationEntries.updating([a], id: a.id, amountMl: 250)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.id, a.id)              // identity preserved
        XCTAssertEqual(after.first?.amountMl, 250)
        XCTAssertEqual(after.first?.loggedAt, a.loggedAt)  // timestamp preserved
    }

    func testUpdatingToNonPositiveDeletesTheEntry() {
        let a = entry(30), b = entry(500)
        let after = HydrationEntries.updating([a, b], id: a.id, amountMl: 0)
        XCTAssertEqual(after.map(\.id), [b.id])
        XCTAssertEqual(HydrationEntries.total(after), 500, accuracy: 0.0001)
    }

    func testUpdatingUnknownIdIsNoOp() {
        let a = entry(30)
        let after = HydrationEntries.updating([a], id: UUID(), amountMl: 999)
        XCTAssertEqual(after.first?.amountMl, 30)
    }
}
