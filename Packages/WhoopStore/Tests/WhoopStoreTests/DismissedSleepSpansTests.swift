import XCTest
import WhoopStore

/// #65: deleting a DETECTED sleep writes a durable tombstone so the next analyze pass does not
/// silently re-detect + re-insert it, WITH an undo that removes the tombstone. `DismissedSleepSpans`
/// is the pure token/window/overlap logic behind that (the Repository owns the UserDefaults I/O and the
/// namespace resolution). These pin: token round-trip, the malformed-token drop stays green, the
/// engine's overlap-suppression predicate, and the hard-cap keeps-newest behaviour.
final class DismissedSleepSpansTests: XCTestCase {

    // MARK: - Token add / remove round-trip

    func testAddThenRemoveRoundTripsToEmpty() {
        var tokens: [String] = []
        tokens = DismissedSleepSpans.adding(startTs: 1000, endTs: 2000, to: tokens)
        XCTAssertEqual(tokens, ["1000:2000"])
        tokens = DismissedSleepSpans.removing(startTs: 1000, endTs: 2000, from: tokens)
        XCTAssertEqual(tokens, [], "undo removes exactly the token it added")
    }

    func testAddIsIdempotent() {
        var tokens = DismissedSleepSpans.adding(startTs: 1000, endTs: 2000, to: [])
        tokens = DismissedSleepSpans.adding(startTs: 1000, endTs: 2000, to: tokens)
        XCTAssertEqual(tokens, ["1000:2000"], "re-deleting the same night does not duplicate the tombstone")
    }

    func testRemoveNonMemberIsNoOp() {
        let tokens = ["1000:2000"]
        XCTAssertEqual(DismissedSleepSpans.removing(startTs: 5, endTs: 6, from: tokens), tokens)
    }

    // MARK: - Window parsing drops malformed tokens (existing behaviour, must stay green)

    func testWindowsDropsMalformedAndNonPositiveWidthTokens() {
        let tokens = ["1000:2000", "garbage", "5:5", "9:3", "3:4:5", "abc:def", "7:9"]
        let windows = DismissedSleepSpans.windows(from: tokens)
        XCTAssertEqual(windows.count, 2, "only the two well-formed positive-width windows survive")
        XCTAssertTrue(windows.contains { $0.start == 1000 && $0.end == 2000 })
        XCTAssertTrue(windows.contains { $0.start == 7 && $0.end == 9 })
    }

    // MARK: - Engine overlap-suppression predicate

    func testOverlappingSessionIsSuppressed() {
        let windows = [(start: 1000, end: 2000)]
        // A re-detected onset that drifted a little still overlaps the dismissed span.
        XCTAssertTrue(DismissedSleepSpans.isSuppressed(sessionStart: 1100, sessionEnd: 2100, windows: windows))
        XCTAssertTrue(DismissedSleepSpans.isSuppressed(sessionStart: 900, sessionEnd: 1500, windows: windows))
    }

    func testDisjointSessionIsNotSuppressed() {
        let windows = [(start: 1000, end: 2000)]
        XCTAssertFalse(DismissedSleepSpans.isSuppressed(sessionStart: 2000, sessionEnd: 3000, windows: windows),
                       "half-open: a session starting exactly at the window end does not overlap")
        XCTAssertFalse(DismissedSleepSpans.isSuppressed(sessionStart: 0, sessionEnd: 1000, windows: windows),
                       "half-open: a session ending exactly at the window start does not overlap")
        XCTAssertFalse(DismissedSleepSpans.isSuppressed(sessionStart: 5000, sessionEnd: 6000, windows: windows))
    }

    func testEmptyWindowsSuppressNothing() {
        XCTAssertFalse(DismissedSleepSpans.isSuppressed(sessionStart: 1000, sessionEnd: 2000, windows: []))
    }

    // MARK: - Tombstone-write policy (userEdited bypass)

    func testDetectedNightWritesTombstoneButUserEditedDoesNot() {
        XCTAssertTrue(DismissedSleepSpans.writesTombstoneOnDelete(userEdited: false),
                      "a detected night is tombstoned so the recompute won't regenerate it")
        XCTAssertFalse(DismissedSleepSpans.writesTombstoneOnDelete(userEdited: true),
                       "a hand-corrected night / manual nap is never re-detected, so no tombstone")
    }

    // MARK: - Hard cap (no age prune; keeps the newest by end-time)

    func testHardCapKeepsNewestByEndTime() {
        // Build cap + 50 tokens, oldest first (increasing end times).
        var tokens: [String] = []
        for i in 0..<(DismissedSleepSpans.hardCap + 50) {
            tokens = DismissedSleepSpans.adding(startTs: i * 10, endTs: i * 10 + 5, to: tokens)
        }
        XCTAssertEqual(tokens.count, DismissedSleepSpans.hardCap, "capped at the hard limit")
        // The newest (largest end) survive; the oldest are dropped.
        let windows = DismissedSleepSpans.windows(from: tokens)
        let newestEnd = (DismissedSleepSpans.hardCap + 50 - 1) * 10 + 5
        XCTAssertTrue(windows.contains { $0.end == newestEnd }, "the newest tombstone is kept")
        XCTAssertFalse(windows.contains { $0.end == 5 }, "the oldest tombstone is dropped")
    }
}
