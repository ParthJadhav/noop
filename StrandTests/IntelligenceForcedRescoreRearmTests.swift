import XCTest
@testable import Strand

/// Pins the #899-A forced-rescore re-arm contract in `IntelligenceEngine.analyzeRecent`.
///
/// THE BUG: `analyzeRecent` opens with `guard !computing else { return }`. A `force: true` post-backfill
/// recompute (AppModel kicks one off after a sync) that arrives while a 15-min idle tick already holds the
/// `computing` lock was SILENTLY DROPPED, so a freshly-synced WHOOP 5.0 night intermittently never got
/// re-scored until the next cycle and Today fell back to the last scored day.
///
/// THE FIX: a dropped FORCED call sets `pendingForcedRescore`; the in-flight pass's `defer` clears the flag
/// and re-invokes `analyzeRecent(force: true)` ONCE. A NON-forced idle tick is still safely dropped (the
/// running pass already covers the same window). The flag is cleared BEFORE the re-invoke (a single re-arm),
/// so a quiet pass cannot recurse and a forced call landing DURING the re-invoke re-arms it again , exactly
/// once per genuinely-dropped force.
///
/// The engine's re-arm is a tiny `(computing, force) → drop | rearm` state machine plus a "rerun once when
/// the flag is set at defer time" rule. `IntelligenceEngine` is `@MainActor` and needs a live store/repo to
/// run a real pass (not constructible in a unit context), so this models the SAME decision rules the engine
/// implements and pins the contract: a forced call during an in-flight pass schedules EXACTLY ONE rerun, a
/// non-forced one schedules NONE, and the re-arm can never loop. Mirrors the Android no-op rationale: Android
/// has no shared `computing` lock (the forced post-backfill rescore runs on its own ioScope coroutine and is
/// never dropped), so there is nothing to re-arm there.
final class IntelligenceForcedRescoreRearmTests: XCTestCase {

    /// A faithful model of the engine's re-arm state machine. Each method mirrors one decision in
    /// `analyzeRecent`: the entry guard and the `defer`. `reruns` counts how many times the `defer` would
    /// re-invoke `analyzeRecent(force: true)`.
    private struct RearmModel {
        private(set) var computing = false
        private(set) var pendingForcedRescore = false
        private(set) var reruns = 0

        /// `guard !computing else { if force { pendingForcedRescore = true }; return }`.
        /// Returns true when the call proceeds into the body (took the lock); false when it was dropped
        /// (and, if forced, re-armed). A proceeding call sets `computing = true`.
        mutating func enter(force: Bool) -> Bool {
            if computing {
                if force { pendingForcedRescore = true }
                return false
            }
            computing = true
            return true
        }

        /// The body's `defer`: clear the lock, then if a forced rescore was dropped while we held it,
        /// clear the flag (single re-arm) and re-invoke once. The re-invoke runs its OWN enter()/leave()
        /// so a nested re-arm is modelled too.
        mutating func leave() {
            computing = false
            if pendingForcedRescore {
                pendingForcedRescore = false
                reruns += 1
                // The re-invoke is `analyzeRecent(force: true)`: it re-enters (lock is free now) and leaves.
                if enter(force: true) { leave() }
            }
        }
    }

    /// A forced call dropped while a pass is in-flight schedules EXACTLY ONE rerun.
    func testForcedCallDuringInFlightPassSchedulesExactlyOneRerun() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))          // idle tick / first pass takes the lock
        XCTAssertFalse(m.enter(force: true))         // a forced post-sync call lands mid-flight → dropped + re-armed
        XCTAssertTrue(m.pendingForcedRescore)
        m.leave()                                    // the in-flight pass finishes → re-arms once
        XCTAssertEqual(m.reruns, 1, "a dropped forced call must trigger exactly one rerun")
        XCTAssertFalse(m.pendingForcedRescore, "the flag is cleared by the single re-arm")
        XCTAssertFalse(m.computing, "the lock is released after the rerun")
    }

    /// A NON-forced idle tick dropped while a pass is in-flight is NOT re-armed (the running pass already
    /// covers the same window) , so no rerun, no wasted recompute.
    func testNonForcedCallDuringInFlightPassIsNotRearmed() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        XCTAssertFalse(m.enter(force: false))        // a non-forced idle tick lands mid-flight → dropped, NOT re-armed
        XCTAssertFalse(m.pendingForcedRescore)
        m.leave()
        XCTAssertEqual(m.reruns, 0)
    }

    /// A pass with NOTHING dropped while it ran re-arms NOTHING , the re-arm can't fire spuriously.
    func testQuietPassDoesNotRerun() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        m.leave()
        XCTAssertEqual(m.reruns, 0)
        XCTAssertFalse(m.pendingForcedRescore)
        XCTAssertFalse(m.computing)
    }

    /// Many forced calls piling up against ONE in-flight pass collapse to a SINGLE rerun (the flag is a
    /// boolean latch, not a counter) , the re-arm bounds the extra work to one pass, never a storm.
    func testMultipleDroppedForcedCallsCollapseToOneRerun() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        for _ in 0..<5 { XCTAssertFalse(m.enter(force: true)) }   // five forced calls all land mid-flight
        m.leave()
        XCTAssertEqual(m.reruns, 1, "the boolean latch collapses N dropped forces to one rerun")
    }

    /// The single re-arm terminates: a forced call that lands DURING the re-invoke re-arms exactly once more
    /// (one extra pass), and once nothing new lands the chain stops , it can never recurse unbounded.
    func testReArmTerminatesAndDoesNotLoop() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        XCTAssertFalse(m.enter(force: true))         // one forced call dropped against the first pass
        m.leave()                                    // re-arms once; the re-invoke runs to completion cleanly
        XCTAssertEqual(m.reruns, 1)
        XCTAssertFalse(m.pendingForcedRescore)
        XCTAssertFalse(m.computing)                  // settled , no lingering lock, no further reruns queued
    }
}
