import XCTest
@testable import WhoopStore

/// #65 x #899 x #940 interaction. A dismissed (deleted) sleep window must stay dismissed across a
/// dedup/heal + rescore: the engine's re-detection guard (`DismissedSleepSpans.isSuppressed`) filters a
/// re-detected overlapping session BEFORE it is ever banked, so the #899 `SleepSessionDedup` heal (which
/// only ever operates on rows that DID get banked) can never resurrect a suppressed night. This models
/// the exact engine sequence: filter re-detected sessions against the tombstones, upsert the survivors,
/// then run the overlap-dedup heal over the stored set, and asserts the suppressed window is gone at
/// every step.
final class DismissedSleepDedupInteractionTests: XCTestCase {

    private func session(start: Int, end: Int, edited: Bool = false) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: nil, restingHr: nil,
                           avgHrv: nil, stagesJSON: nil, userEdited: edited)
    }

    /// The engine's guard step: drop freshly-detected sessions overlapping any dismissed window (mirrors
    /// IntelligenceEngine's `cachedSleepKept` filter, which now delegates to `DismissedSleepSpans`).
    private func kept(_ detected: [CachedSleepSession],
                      dismissed windows: [(start: Int, end: Int)]) -> [CachedSleepSession] {
        detected.filter { !DismissedSleepSpans.isSuppressed(sessionStart: $0.startTs,
                                                            sessionEnd: $0.endTs, windows: windows) }
    }

    func testDismissedWindowIsDroppedBeforeBankingAndStaysDroppedAfterDedup() {
        // Night A (kept) at day D-1, Night B (DELETED) at day D. A re-detects clean; B re-detects with a
        // drifted onset, still overlapping the tombstone.
        let nightA = session(start: 100_000, end: 128_000)
        let nightBReDetected = session(start: 200_500, end: 228_000)   // drifted 500s from the deleted onset
        let tombstones = DismissedSleepSpans.windows(from: [DismissedSleepSpans.token(startTs: 200_000, endTs: 228_000)])

        // STEP 1 (engine guard): B is suppressed, A survives.
        let survivors = kept([nightA, nightBReDetected], dismissed: tombstones)
        XCTAssertEqual(survivors.map(\.startTs), [nightA.startTs],
                       "the re-detected deleted night is filtered before it is ever banked")

        // STEP 2 (the #899 heal) runs over the BANKED set (only the survivors were upserted). A stale,
        // timebase-shifted duplicate of night A got banked on an earlier pass; the heal collapses it.
        let staleADuplicate = session(start: 100_500, end: 128_500)    // overlaps A → same night, drop it
        let banked = survivors + [staleADuplicate]
        let result = SleepSessionDedup.dedupe(banked, freshStarts: [nightA.startTs])
        XCTAssertEqual(result.kept.map(\.startTs), [nightA.startTs], "one survivor for night A")

        // STEP 3 (invariant): the dedup heal NEVER re-introduces the suppressed window. B is nowhere in
        // the kept set, and the tombstone list is untouched by the heal (it operates on rows, not spans).
        XCTAssertFalse(result.kept.contains { DismissedSleepSpans.isSuppressed(sessionStart: $0.startTs,
                                                                              sessionEnd: $0.endTs,
                                                                              windows: tombstones) },
                       "no kept row overlaps the dismissed window after a dedup+rescore")
    }

    func testRemovingTheTombstoneReAdmitsTheNightOnTheNextPass() {
        // The undo / "allow re-detection" escape hatch: once the tombstone is gone, the re-detected night
        // is banked normally on the next analyze pass.
        let nightBReDetected = session(start: 200_500, end: 228_000)
        var tokens = [DismissedSleepSpans.token(startTs: 200_000, endTs: 228_000)]

        // While tombstoned: suppressed.
        XCTAssertTrue(kept([nightBReDetected], dismissed: DismissedSleepSpans.windows(from: tokens)).isEmpty)

        // Remove the tombstone (undo) → re-admitted.
        tokens = DismissedSleepSpans.removing(startTs: 200_000, endTs: 228_000, from: tokens)
        XCTAssertEqual(kept([nightBReDetected], dismissed: DismissedSleepSpans.windows(from: tokens)).map(\.startTs),
                       [nightBReDetected.startTs], "lifting the tombstone re-admits the night")
    }

    func testEditedNightIsNeverSuppressedByTheDedupSurvivorRule() {
        // A userEdited night is exempt from dedup drops (SleepSessionDedup keeps edited rows), and the
        // delete path writes NO tombstone for it, so a userEdited night is never suppressed here.
        let edited = session(start: 300_000, end: 328_000, edited: true)
        let overlappingDetected = session(start: 300_200, end: 328_000)
        let result = SleepSessionDedup.dedupe([edited, overlappingDetected], freshStarts: [overlappingDetected.startTs])
        XCTAssertTrue(result.kept.contains { $0.userEdited }, "the edited night is never dropped by the heal")
    }
}
