import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
@testable import StrandAnalytics

final class SleepStageTotalsTests: XCTestCase {

    func testMinutesFromSegmentArray() throws {
        let json = """
        [{"start":0,"end":600,"stage":"light"},
         {"start":600,"end":1200,"stage":"deep"},
         {"start":1200,"end":1500,"stage":"wake"}]
        """
        let m = try XCTUnwrap(SleepStageTotals.minutes(fromStagesJSON: json))
        XCTAssertEqual(m.light, 10, accuracy: 0.001)
        XCTAssertEqual(m.deep, 10, accuracy: 0.001)
        XCTAssertEqual(m.awake, 5, accuracy: 0.001)   // "wake" → awake
        XCTAssertEqual(m.asleep, 20, accuracy: 0.001)
        XCTAssertEqual(m.inBed, 25, accuracy: 0.001)
    }

    func testMinutesFromMinuteDict() throws {
        let m = try XCTUnwrap(SleepStageTotals.minutes(fromStagesJSON:
            #"{"awake":20,"light":200,"deep":80,"rem":90}"#))
        XCTAssertEqual(m.asleep, 370, accuracy: 0.001)
        XCTAssertEqual(m.inBed, 390, accuracy: 0.001)
    }

    func testDailyAggregateSumsBlocksAndComputesEfficiency() throws {
        let agg = try XCTUnwrap(SleepStageTotals.dailyAggregate([
            #"{"awake":10,"light":100,"deep":40,"rem":50}"#,   // a nap-ish block
            #"{"awake":10,"light":100,"deep":40,"rem":40}"#,
        ]))
        XCTAssertEqual(agg.totalSleepMin, 370, accuracy: 0.001)   // (190 + 180)
        XCTAssertEqual(agg.deepMin, 80, accuracy: 0.001)
        XCTAssertEqual(agg.efficiency, 370.0 / 390.0, accuracy: 0.0001)
    }

    func testNilAndGarbage() {
        XCTAssertNil(SleepStageTotals.minutes(fromStagesJSON: nil))
        XCTAssertNil(SleepStageTotals.minutes(fromStagesJSON: "nope"))
        XCTAssertNil(SleepStageTotals.dailyAggregate([nil, "garbage"]))
    }

    // MARK: - the integration seam: detected blocks + edits → corrected daily

    private let detectedNight = "2026-06-14T23:24"  // doc only
    private func detected(_ startTs: Int, _ stages: String) -> (startTs: Int, stagesJSON: String?) {
        (startTs: startTs, stagesJSON: stages)
    }

    func testHonoringEditsNoEditsLeavesDetectedSumAndFlagsFalse() throws {
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [detected(1000, #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [:]))
        XCTAssertFalse(r.editApplied)
        XCTAssertEqual(r.sleep.totalSleepMin, 392, accuracy: 0.001)   // 214+82+96
    }

    func testHonoringEditsSubstitutesEditedBlockByStartTs() throws {
        // Detected says 6h32m; the user's edit (same startTs 1000) trimmed it to ~4h56m.
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [detected(1000, #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [1000: #"{"awake":0,"light":118,"deep":82,"rem":96}"#]))
        XCTAssertTrue(r.editApplied, "a startTs match must apply the edit")
        XCTAssertEqual(r.sleep.totalSleepMin, 296, accuracy: 0.001, "totals come from the EDITED stages")
        XCTAssertEqual(r.sleep.lightMin, 118, accuracy: 0.001)
        XCTAssertEqual(r.sleep.efficiency, 296.0 / 296.0, accuracy: 0.001) // awake 0 → 100% efficient
    }

    func testHonoringEditsKeepsDetectedWhenEditMapsToNil() throws {
        // An edit whose reshaped stages came out nil must FALL BACK to the detected block, never drop it
        // (which would collapse the night's sleep total). (#318 review #4)
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: 1000, stagesJSON: #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [1000: nil]))
        XCTAssertFalse(r.editApplied, "a nil edit is not a usable substitution")
        XCTAssertEqual(r.sleep.totalSleepMin, 392, accuracy: 0.001, "detected stages kept, not dropped")
    }

    func testHonoringEditsIgnoresEditWithNonMatchingStartTs() throws {
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [detected(1000, #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [9999: #"{"awake":0,"light":10,"deep":10,"rem":10}"#]))  // wrong key
        XCTAssertFalse(r.editApplied, "an edit that matches no detected block must not apply")
        XCTAssertEqual(r.sleep.totalSleepMin, 392, accuracy: 0.001)
    }

    func testHonoringEditsMultiBlockSubstitutesOnlyTheEditedBlock() throws {
        // A nap (startTs 100, untouched) + a main sleep (startTs 1000, edited shorter).
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [detected(100, #"{"awake":2,"light":30,"deep":10,"rem":8}"#),
                       detected(1000, #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [1000: #"{"awake":0,"light":118,"deep":82,"rem":96}"#]))
        XCTAssertTrue(r.editApplied)
        // nap asleep 48 + edited main asleep 296 = 344
        XCTAssertEqual(r.sleep.totalSleepMin, 344, accuracy: 0.001)
    }

    /// The point of the whole exercise: a shorter (hand-corrected) window yields a LOWER Rest composite,
    /// so the daily aggregate genuinely moves when sleep is trimmed — not just the Sleep tab's label.
    func testRestCompositeDropsWhenEditedWindowIsShorter() throws {
        func daily(_ s: SleepStageTotals.DailySleep) -> DailyMetric {
            DailyMetric(day: "2026-06-15", totalSleepMin: s.totalSleepMin, efficiency: s.efficiency,
                        deepMin: s.deepMin, remMin: s.remMin, lightMin: s.lightMin, disturbances: nil,
                        restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
        }
        let detected = try XCTUnwrap(SleepStageTotals.dailyAggregate(
            [#"{"awake":24,"light":214,"deep":82,"rem":96}"#]))               // ~6h32m asleep
        let edited = try XCTUnwrap(SleepStageTotals.dailyAggregate(
            [#"{"awake":0,"light":118,"deep":82,"rem":96}"#]))                // woke ~2h earlier

        let before = try XCTUnwrap(AnalyticsEngine.Rest.composite(daily: daily(detected)))
        let after = try XCTUnwrap(AnalyticsEngine.Rest.composite(daily: daily(edited)))
        XCTAssertLessThan(after, before, "trimming sleep must lower the Rest composite")
    }

    // MARK: - #525 canonical main-night selection (numbers reconcile across screens)

    /// A "yyyy-MM-dd'T'HH:mm" UTC wall-clock as unix seconds. UTC offset 0 in these tests, so local == UTC.
    private func ts525(_ iso: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return Int(f.date(from: iso)!.timeIntervalSince1970)
    }

    func testMainNightPrefersOvernightOverLongerDaytimeNap() {
        let nightStart = ts525("2026-06-14T23:00")   // overnight onset
        let napStart   = ts525("2026-06-15T13:00")   // daytime onset
        // The nap is LONGER in clock span, but the overnight block must still win.
        let blocks = [
            SleepStageTotals.NightBlock(start: napStart,   end: napStart + 5 * 3600),  // 5h daytime
            SleepStageTotals.NightBlock(start: nightStart, end: nightStart + 4 * 3600), // 4h overnight
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 1,
                       "the overnight block is the main night even when a nap is longer")
    }

    func testMainNightLongestAmongOvernightBlocks() {
        let a = ts525("2026-06-14T22:00")
        let b = ts525("2026-06-14T23:30")
        let blocks = [
            SleepStageTotals.NightBlock(start: a, end: a + 3 * 3600),  // 3h
            SleepStageTotals.NightBlock(start: b, end: b + 6 * 3600),  // 6h — longer overnight wins
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 1)
    }

    func testMainNightEmptyAndTieAreDeterministic() {
        XCTAssertNil(SleepStageTotals.mainNightIndex([], offsetSec: 0))
        // Two SCORE-TIED blocks (equal duration AND equal circular distance to the cold-start anchor,
        // mirrored either side of 03:30) → the EARLIER onset breaks the tie (stable across platforms).
        let early = ts525("2026-06-15T00:30")  // 4h → mid 02:30, 1h before the 03:30 anchor
        let late  = ts525("2026-06-15T02:30")  // 4h → mid 04:30, 1h after  → SAME bonus, SAME duration
        let blocks = [
            SleepStageTotals.NightBlock(start: late,  end: late  + 4 * 3600),
            SleepStageTotals.NightBlock(start: early, end: early + 4 * 3600),
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 1,
                       "score tie (equal duration + equal anchor distance) → earlier onset breaks it")
    }

    /// #555 regression: a biphasic / briefly-interrupted main night (fragments split by short wakes) must
    /// resolve to ONE bridged GROUP containing ALL its fragments, while a distant afternoon nap stays
    /// OUTSIDE the group. The Sleep tab classifies naps as "not in this group" and aggregates the group for
    /// the hero, so the bridged siblings are no longer rendered as phantom naps the way the bare
    /// single-block selector left them (the #555 report: "three naps instead of a continuous sleep").
    func testBiphasicNightGroupsAllFragmentsAndExcludesNap() {
        // Three fragments of ONE night, each separated by a < 60 min wake gap (so they bridge), plus an
        // afternoon nap > 60 min away (so it does NOT bridge).
        let f1  = ts525("2026-06-14T23:00")          // 23:00–01:00
        let f2  = ts525("2026-06-15T01:40")          // 01:40–04:00  (40 min gap → bridges)
        let f3  = ts525("2026-06-15T04:30")          // 04:30–07:00  (30 min gap → bridges)
        let nap = ts525("2026-06-15T14:00")          // 14:00–15:00  (7 h gap → does NOT bridge)
        let blocks = [
            SleepStageTotals.NightBlock(start: f1,  end: f1  + 2 * 3600),
            SleepStageTotals.NightBlock(start: f2,  end: f2  + 140 * 60),
            SleepStageTotals.NightBlock(start: f3,  end: f3  + 150 * 60),
            SleepStageTotals.NightBlock(start: nap, end: nap + 3600),
        ]
        let group = SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: 0)
        XCTAssertEqual(group, [0, 1, 2],
                       "all three bridged night fragments are the main group; the afternoon nap is excluded")
        // The BARE single-block selector picks only ONE fragment — exactly why the un-bridged tab labelled
        // the other two as naps. The GROUP is what the tab and engine must share. (#555)
        let single = SleepStageTotals.mainNightIndex(blocks, offsetSec: 0)
        XCTAssertNotNil(single)
        XCTAssertTrue([0, 1, 2].contains(single ?? -1),
                      "the bare winner is one of the night fragments, never the afternoon nap")
        XCTAssertFalse(group?.contains(3) ?? true, "the afternoon nap is never in the main-night group")
    }

    /// IRON-RULE REGRESSION GUARD (#547 / #407 lanes): the 6.1.1 bridged main-night SELECTION must NOT move
    /// when the upstream ingest gate (#547) or the downstream motion trace (#407) change. This pins
    /// `mainNightGroupIndices` for a biphasic main night to a BYTE-IDENTICAL expected output so any future
    /// edit that perturbs `mainNightGroupIndices` / `mainNightIndex` / the bridge is caught immediately.
    /// The values are hard-coded (not re-derived) so the test is a frozen golden, exactly the "before/after"
    /// the lane brief requires.
    func testMainNightGroupIndicesByteIdenticalForBiphasicNight() {
        // A biphasic main night: two fragments split by a 35-min wake gap (< gapBridgeMaxMin → they bridge),
        // plus a far-away afternoon nap that must stay OUT of the group. Same shape as the bridge fixture.
        let a   = ts525("2026-06-14T23:10")              // 23:10–01:30
        let b   = ts525("2026-06-15T02:05")              // 02:05–06:40  (35 min gap → bridges)
        let nap = ts525("2026-06-15T15:00")              // 15:00–16:20  (far → does NOT bridge)
        let blocks = [
            SleepStageTotals.NightBlock(start: a,   end: a   + 140 * 60),   // idx 0
            SleepStageTotals.NightBlock(start: b,   end: b   + 275 * 60),   // idx 1
            SleepStageTotals.NightBlock(start: nap, end: nap +  80 * 60),   // idx 2
        ]
        // FROZEN GOLDEN: the two bridged night fragments are the group; the nap is excluded. If this value
        // changes, the 6.1.1 main-night selection moved — STOP and investigate (the iron rule).
        XCTAssertEqual(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: 0), [0, 1])
        // Cold-start AND learned-habitual must both land identically (the selection is timing-independent
        // here because the night dominates by duration), proving neither path perturbs the bridge.
        let habitualMid = SleepStageTotals.localSecOfDay(a + 140 * 60 / 2, offsetSec: 0)
        XCTAssertEqual(
            SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: 0, habitualMidsleepSec: habitualMid),
            [0, 1])
        // And the bare single-block winner stays inside the group (never the nap).
        XCTAssertTrue([0, 1].contains(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0) ?? -1))
    }

    /// THE #525 invariant: a day with an overnight + a nap reports CONSISTENT totals — the day's
    /// canonical figure equals the MAIN NIGHT's sleep, NOT the night+nap sum. The honoring-edits seam
    /// (with onsets supplied) and the standalone main-night aggregate agree to the minute.
    func testOvernightPlusNapReportsConsistentTotalsNotTheSum() throws {
        let nightStart = ts525("2026-06-14T23:00")
        let napStart   = ts525("2026-06-15T14:00")
        let nightStages = #"{"awake":24,"light":214,"deep":82,"rem":96}"#   // 392 min asleep
        let napStages   = #"{"awake":2,"light":30,"deep":10,"rem":8}"#      // 48 min asleep

        // What the Sleep tab's hero shows for this day = the main night's own aggregate.
        let mainOnly = try XCTUnwrap(SleepStageTotals.dailyAggregate([nightStages]))
        XCTAssertEqual(mainOnly.totalSleepMin, 392, accuracy: 0.001)

        // The honoring-edits seam (no edits, but onsets supplied) must report the SAME main-night total,
        // never the 392 + 48 = 440 sum the old code produced.
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: nightStart, stagesJSON: nightStages),
                       (startTs: napStart,   stagesJSON: napStages)],
            edited: [:],
            onsetByStart: [nightStart: nightStart, napStart: napStart],
            offsetSec: 0))
        XCTAssertFalse(r.editApplied)
        XCTAssertEqual(r.sleep.totalSleepMin, mainOnly.totalSleepMin, accuracy: 0.001,
                       "day total must equal the MAIN night, not the night+nap sum")
        XCTAssertEqual(r.sleep.deepMin, mainOnly.deepMin, accuracy: 0.001)
        XCTAssertEqual(r.sleep.remMin, mainOnly.remMin, accuracy: 0.001)
        XCTAssertNotEqual(r.sleep.totalSleepMin, 440, accuracy: 0.001, "must NOT sum the nap in")
    }

    /// A hand-corrected (trimmed) main night still wins the pick, and the day total tracks the EDITED
    /// main night — the nap is never folded into the headline figure.
    func testHonoringEditsMainNightModeTracksEditedNightNotNapSum() throws {
        let nightStart = ts525("2026-06-14T23:00")
        let napStart   = ts525("2026-06-15T14:00")
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: nightStart, stagesJSON: #"{"awake":24,"light":214,"deep":82,"rem":96}"#),
                       (startTs: napStart,   stagesJSON: #"{"awake":2,"light":30,"deep":10,"rem":8}"#)],
            edited: [nightStart: #"{"awake":0,"light":118,"deep":82,"rem":96}"#],   // trimmed to 296
            onsetByStart: [nightStart: nightStart, napStart: napStart],
            offsetSec: 0))
        XCTAssertTrue(r.editApplied)
        XCTAssertEqual(r.sleep.totalSleepMin, 296, accuracy: 0.001,
                       "day total tracks the EDITED main night, nap excluded from the headline figure")
    }

    /// Backward-compat: with NO onsets supplied the seam keeps the legacy sum-of-all-blocks total, so
    /// any caller still on the old signature is unchanged.
    func testHonoringEditsLegacySumWhenNoOnsets() throws {
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: 100,  stagesJSON: #"{"awake":2,"light":30,"deep":10,"rem":8}"#),
                       (startTs: 1000, stagesJSON: #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [:]))
        XCTAssertEqual(r.sleep.totalSleepMin, 48 + 392, accuracy: 0.001, "no onsets → legacy sum")
    }

    // MARK: - #777/#705 inter-fragment awake (out-of-bed gap between bridged fragments)

    /// The shared definition: sum only the POSITIVE gaps between consecutive (start,end) spans, sorted by
    /// start. Abutting / overlapping fragments contribute 0; an unsorted input is sorted first.
    func testInterFragmentAwakeSecondsSumsPositiveGapsOnly() {
        // One 20-min gap between two fragments (06:00 → 06:20).
        let f1 = (start: 0, end: 6 * 3600)
        let f2 = (start: 6 * 3600 + 20 * 60, end: 9 * 3600)
        XCTAssertEqual(SleepStageTotals.interFragmentAwakeSeconds([f1, f2]), Double(20 * 60), accuracy: 0.001)
        // Order-independent: passing them reversed yields the SAME gap.
        XCTAssertEqual(SleepStageTotals.interFragmentAwakeSeconds([f2, f1]), Double(20 * 60), accuracy: 0.001)
        // Abutting fragments (no gap) → 0; a single fragment → 0.
        XCTAssertEqual(SleepStageTotals.interFragmentAwakeSeconds([(0, 100), (100, 200)]), 0, accuracy: 0.001)
        XCTAssertEqual(SleepStageTotals.interFragmentAwakeSeconds([(0, 100)]), 0, accuracy: 0.001)
        // Two gaps across three fragments sum.
        let three = [(0, 100), (160, 300), (340, 500)]  // 60s + 40s = 100s
        XCTAssertEqual(SleepStageTotals.interFragmentAwakeSeconds(three), 100, accuracy: 0.001)
    }

    /// #777/#705 regression fixture: a main night bridged from two fragments split by a 20-min OUT-OF-BED
    /// gap must report ~20 min AWAKE on the day's rollup (it read as ~0 before). The seam folds the gap into
    /// AWAKE via the in-bed denominator - in-bed = asleep + (fragment awake + gap) - with NO double-count.
    func testHonoringEditsFragmentedNightCountsGapAsAwake() throws {
        // Two fragments of ONE night, each 0 staged-awake, split by a 20-min gap (< gapBridgeMaxMin → they
        // bridge into the main-night group). Fragment 1: 23:00–02:00 (180 min asleep). 20-min gap. Fragment
        // 2: 02:20–06:00 (220 min asleep). Per-fragment stages carry 0 awake, so without the fix the gap
        // would vanish.
        let f1Start = ts525("2026-06-14T23:00")
        let f2Start = ts525("2026-06-15T02:20")  // 20-min gap after f1's 02:00 end
        let f1Stages = #"{"awake":0,"light":120,"deep":30,"rem":30}"#   // 180 min asleep, 180 in-bed
        let f2Stages = #"{"awake":0,"light":140,"deep":40,"rem":40}"#   // 220 min asleep, 220 in-bed

        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: f1Start, stagesJSON: f1Stages),
                       (startTs: f2Start, stagesJSON: f2Stages)],
            edited: [:],
            onsetByStart: [f1Start: f1Start, f2Start: f2Start],
            offsetSec: 0))
        XCTAssertFalse(r.editApplied)
        // Asleep is the SUM of the two fragments (180 + 220 = 400 min); the gap is awake, not sleep.
        XCTAssertEqual(r.sleep.totalSleepMin, 400, accuracy: 0.001, "asleep is the sum of both fragments")
        // In-bed = 180 + 220 + 20 (gap) = 420 min. Awake = in-bed − asleep = 20 min (the gap), NOT ~0.
        let awakeMin = r.sleep.totalSleepMin / r.sleep.efficiency - r.sleep.totalSleepMin
        XCTAssertEqual(awakeMin, 20, accuracy: 0.01, "the 20-min out-of-bed gap reads as ~20 min awake (#777)")
        XCTAssertEqual(r.sleep.efficiency, 400.0 / 420.0, accuracy: 0.0001, "efficiency reflects the gap")
    }

    /// The seam definition and the standalone aggregate agree to the minute (no double-count): feeding the
    /// SAME gap to `dailyAggregate(_:interFragmentAwakeSeconds:)` yields the identical in-bed/awake the seam
    /// reports, proving the two paths share one definition (the PR #787 seam bug this fix avoids).
    func testInterFragmentAwakeFoldsConsistentlyNoDoubleCount() throws {
        let f1Stages = #"{"awake":0,"light":120,"deep":30,"rem":30}"#   // 180 asleep
        let f2Stages = #"{"awake":0,"light":140,"deep":40,"rem":40}"#   // 220 asleep
        let agg = try XCTUnwrap(SleepStageTotals.dailyAggregate([f1Stages, f2Stages],
                                                                interFragmentAwakeSeconds: Double(20 * 60)))
        XCTAssertEqual(agg.totalSleepMin, 400, accuracy: 0.001)
        XCTAssertEqual(agg.efficiency, 400.0 / 420.0, accuracy: 0.0001)
        // A zero gap reproduces the legacy behaviour exactly (backward-compat).
        let legacy = try XCTUnwrap(SleepStageTotals.dailyAggregate([f1Stages, f2Stages]))
        let folded0 = try XCTUnwrap(SleepStageTotals.dailyAggregate([f1Stages, f2Stages],
                                                                    interFragmentAwakeSeconds: 0))
        XCTAssertEqual(legacy.efficiency, folded0.efficiency, accuracy: 1e-12)
    }

    // MARK: - #547 learned-timing scored selector (the gate is gone)

    /// Local time-of-day "HH:mm" → seconds, for habitual-midsleep expectations.
    private func sod(_ hhmm: String) -> Int {
        let p = hhmm.split(separator: ":"); return Int(p[0])! * 3600 + Int(p[1])! * 60
    }

    /// THE pikapik case: a genuinely LONG sleep whose detected onset falls in the daytime gap
    /// [10:00, 20:00) must beat a SHORT overnight fragment. Under the old hard gate the overnight
    /// fragment always won and the real sleep got tagged a nap; the score now lets duration prevail.
    func testLongDaytimeOnsetBeatsShortOvernightFragment() {
        let dayLong = ts525("2026-06-15T11:00")   // onset in the daytime gap, 7h long
        let nightFrag = ts525("2026-06-14T23:00") // overnight onset, only 1.5h
        let blocks = [
            SleepStageTotals.NightBlock(start: dayLong,   end: dayLong + 7 * 3600),     // 420 + ~0 bonus
            SleepStageTotals.NightBlock(start: nightFrag, end: nightFrag + 90 * 60),    // 90 + up-to-90 bonus
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 0,
                       "a real 7h daytime-onset sleep outscores a 1.5h overnight fragment (#547 pikapik)")
    }

    /// The reconciled window: a [10:00, 11:00) onset (kept as "night" by the detector but demoted to a
    /// "nap" by the OLD selector window [20:00, 10:00)) must now resolve the SAME way on both sides. With
    /// the band closed at 11:00, a 10:30-onset block earns the overnight bonus like the detector expects.
    func testTenThirtyOnsetIsTreatedAsOvernightNotDaytime() {
        // Bonus parity check: a 10:30 onset is inside the reconciled [20:00,11:00) band.
        XCTAssertTrue(SleepStageTotals.isOvernightOnset(ts525("2026-06-15T10:30"), offsetSec: 0),
                      "10:30 is overnight under the reconciled [20:00,11:00) band (off-by-one fixed)")
        // Selection consistency: with the band closed at 11:00, a 10:30-onset block is treated like any
        // other onset by the SCORE (no special gate). Equal-duration blocks both past the bonus zero
        // distance tie on score, so the earlier onset wins deterministically — the same result the
        // detector's [20:00,11:00) classification implies (no off-by-one disagreement).
        let early = ts525("2026-06-15T10:30")  // 3h, mid 12:00
        let nap   = ts525("2026-06-15T15:00")  // 3h, mid 16:30 (both beyond the 5h bonus zero → bonus 0)
        let blocks = [
            SleepStageTotals.NightBlock(start: nap,   end: nap   + 3 * 3600),
            SleepStageTotals.NightBlock(start: early, end: early + 3 * 3600),
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 1,
                       "score tie → earlier onset wins; the [10,11) boundary no longer disagrees")
    }

    /// A late/shift sleeper: when the habitual midsleep is the AFTERNOON, a daytime sleep is the MAIN
    /// block, even though it would fail any fixed overnight gate. Timing, learned, drives the pick.
    func testHabitualMidsleepShiftsThePickForADaytimeSleeper() {
        let habitual = sod("14:00")                 // this user sleeps midday→afternoon
        let dayBlock   = ts525("2026-06-15T11:00")  // 6h daytime sleep, mid 14:00 (on the habitual)
        let nightBlock = ts525("2026-06-14T23:00")  // 6h overnight, mid 02:00 (far from 14:00)
        let blocks = [
            SleepStageTotals.NightBlock(start: nightBlock, end: nightBlock + 6 * 3600),
            SleepStageTotals.NightBlock(start: dayBlock,   end: dayBlock   + 6 * 3600),
        ]
        // Equal duration → the habitual-aligned daytime block wins on the bonus.
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0, habitualMidsleepSec: habitual), 1,
                       "with a 14:00 habitual midsleep the daytime sleep is the main block")
        // Sanity: with NO habitual (cold-start band, anchored ~03:30) the overnight block wins instead.
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 0,
                       "cold-start band still favors the overnight block")
    }

    /// #518 intent preserved via TIMING, not a gate: a 5h AFTERNOON block vs a 4h block at the habitual
    /// night → the habitual-aligned NIGHT block wins despite being shorter, because its alignment bonus
    /// (full 90) outweighs the afternoon block's extra 60 min with no bonus.
    func testHabitualAlignedShorterNightBeatsLongerAfternoon() {
        let habitual = sod("03:00")                 // a normal sleeper
        let afternoon = ts525("2026-06-15T13:00")   // 5h afternoon = 300, mid 15:30, bonus 0
        let night     = ts525("2026-06-15T01:00")   // 4h at the habitual = 240, mid 03:00, bonus 90 → 330
        let blocks = [
            SleepStageTotals.NightBlock(start: afternoon, end: afternoon + 5 * 3600),
            SleepStageTotals.NightBlock(start: night,     end: night     + 4 * 3600),
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0, habitualMidsleepSec: habitual), 1,
                       "the habitual-aligned 4h night beats a 5h afternoon (timing, not a hard floor)")
    }

    // MARK: - #518 invariant: a realistic daytime nap can NEVER out-rank the real night (R1)

    // After the #547 gate removal the invariant "a nap can't out-rank the real night" is protected ONLY
    // by the +90 min alignment margin (score = asleepMinutes + bonus, bonus ∈ [0, 90]). The exact rule:
    // a non-main block out-scores the night iff its asleep duration exceeds the night's by MORE than
    // (night_bonus − nap_bonus) ≤ 90. So a daytime block must be > the night + 90 min to win.
    //
    // Cold-start anchor is 03:30. A real ≥4h night scores ≥240. A TRUE daytime doze (onset ≥06:00,
    // ≤180 min) tops out at 210 (onset 06:00, 180 min, mid 07:30 → bonus 30), so 210 < 240 — the night
    // ALWAYS wins. (The only path to a 240 *tie* is a 180-min sleep onset 05:00 — a dawn main-sleep, not
    // a nap — and a tie breaks to the EARLIER onset, which an evening-onset night satisfies.) Under a
    // learned night-time habitual the night gets +90 and a far-off nap +0, so the margin is even larger.
    // These tests PIN that across the realistic 20–180 min nap range vs a real 4h+ night, both timings.

    /// A realistic daytime nap (20–180 min, onset across the whole day) can NEVER beat a real 4h+ night,
    /// COLD-START. Exhaustive sweep over the realistic ranges — every case the night must win or tie-win.
    func testRealisticNapNeverBeatsRealNightColdStart() {
        // A real night: 4h..9h, onset 20:00..01:00 (overnight). Daytime naps: 20..180 min, onset 06:00..21:00.
        let nightOnsets = ["2026-06-14T20:00", "2026-06-14T22:00", "2026-06-14T23:00", "2026-06-15T00:00",
                           "2026-06-15T01:00"]
        let nightHours = [4, 5, 6, 7, 8, 9]
        let napOnsets = ["2026-06-15T06:00", "2026-06-15T08:00", "2026-06-15T10:00", "2026-06-15T12:00",
                         "2026-06-15T13:00", "2026-06-15T15:00", "2026-06-15T17:00", "2026-06-15T19:00",
                         "2026-06-15T21:00"]
        let napMins = [20, 30, 45, 60, 90, 120, 150, 180]
        for no in nightOnsets {
            for nh in nightHours {
                let nStart = ts525(no)
                for po in napOnsets {
                    for pm in napMins {
                        let pStart = ts525(po)
                        // Index 1 = the night → the night must always be picked (never the nap at index 0).
                        let blocks = [
                            SleepStageTotals.NightBlock(start: pStart, end: pStart + pm * 60),
                            SleepStageTotals.NightBlock(start: nStart, end: nStart + nh * 3600),
                        ]
                        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 1,
                            "cold-start: a \(pm)min nap@\(po) must NOT out-rank a \(nh)h night@\(no)")
                    }
                }
            }
        }
    }

    /// Same pin, LEARNED-TIMING: with a normal night habitual (03:00) the real night earns the full +90
    /// and a daytime nap earns 0 (>5h circular away), so the night wins by an even larger margin.
    func testRealisticNapNeverBeatsRealNightLearnedTiming() {
        let habitual = sod("03:00")
        let nightOnsets = ["2026-06-14T22:00", "2026-06-14T23:00", "2026-06-15T00:00", "2026-06-15T01:00"]
        let nightHours = [4, 5, 6, 7, 8]
        let napOnsets = ["2026-06-15T10:00", "2026-06-15T12:00", "2026-06-15T13:00", "2026-06-15T15:00",
                         "2026-06-15T17:00", "2026-06-15T19:00"]
        let napMins = [20, 45, 60, 90, 120, 150, 180]
        for no in nightOnsets {
            for nh in nightHours {
                let nStart = ts525(no)
                for po in napOnsets {
                    for pm in napMins {
                        let pStart = ts525(po)
                        let blocks = [
                            SleepStageTotals.NightBlock(start: pStart, end: pStart + pm * 60),
                            SleepStageTotals.NightBlock(start: nStart, end: nStart + nh * 3600),
                        ]
                        XCTAssertEqual(
                            SleepStageTotals.mainNightIndex(blocks, offsetSec: 0, habitualMidsleepSec: habitual), 1,
                            "learned: a \(pm)min nap@\(po) must NOT out-rank a \(nh)h night@\(no)")
                    }
                }
            }
        }
    }

    /// The tightest cold-start margin: a 4h night onset 20:00 (mid 22:00, bonus 0 → score 240) vs the
    /// single most-favourable TRUE-daytime doze (onset 06:00, 180 min, mid 07:30, bonus 30 → score 210).
    /// The night wins by exactly 30. This is the worst case in the realistic range; pin it explicitly so
    /// any future change to the bonus shape/size that would erode this margin trips the test.
    func testTightestColdStartMarginNightStillWins() {
        let night = ts525("2026-06-14T20:00")      // 4h, mid 22:00 → bonus 0 → 240
        let bestNap = ts525("2026-06-15T06:00")    // 180min, mid 07:30 → bonus 30 → 210
        let blocks = [
            SleepStageTotals.NightBlock(start: bestNap, end: bestNap + 180 * 60),
            SleepStageTotals.NightBlock(start: night,   end: night   + 4 * 3600),
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 1,
                       "worst-case realistic doze (210) still loses to a barely-timed 4h night (240)")
    }

    /// The genuinely-ambiguous case is NOT a regression and is DEFENSIBLE: a short 4h night + a LONG 6h
    /// daytime sleep → the 6h block is the main (longest qualifying block wins, per the sleep-timing
    /// research). The user can edit, and the guidance layer explains it. This pins the INTENTIONAL
    /// behaviour so a future "harden the night" change can't silently flip it back to the short night.
    func testAmbiguousLongDaytimeSleepBeatsShortNightByDesign() {
        let night = ts525("2026-06-14T23:00")      // 4h overnight = 240, mid 01:00, cold-start bonus 75 → 315
        let dayLong = ts525("2026-06-15T12:00")    // 6h daytime  = 360, mid 15:00, bonus 0 → 360
        let blocks = [
            SleepStageTotals.NightBlock(start: night,   end: night   + 4 * 3600),
            SleepStageTotals.NightBlock(start: dayLong, end: dayLong + 6 * 3600),
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 1,
            "a 6h daytime sleep (360) beats a 4h night even WITH its bonus (315) — longest wins, by design")
    }

    /// Nap-only day (NO hard duration floor): a single short daytime nap still resolves to a main block,
    /// so the day has a sleep figure rather than nil.
    func testNapOnlyDayResolvesToTheNapAsMain() throws {
        let nap = ts525("2026-06-15T13:00")  // 40 min daytime nap, the only block
        XCTAssertEqual(SleepStageTotals.mainNightIndex(
            [SleepStageTotals.NightBlock(start: nap, end: nap + 40 * 60)], offsetSec: 0), 0,
            "a lone nap is the main block (no hard nap floor)")
        // And via the stage seam: the nap's own minutes become the day's figure.
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: nap, stagesJSON: #"{"awake":2,"light":24,"deep":8,"rem":6}"#)],
            edited: [:],
            onsetByStart: [nap: nap], offsetSec: 0))
        XCTAssertEqual(r.sleep.totalSleepMin, 38, accuracy: 0.001, "nap-only day reports the nap's sleep")
    }

    /// Biphasic / bridged night: two sleep runs separated by a < 60 min wake are one block for selection.
    func testGapBridgeMergesShortWakeSplitNight() {
        let a = ts525("2026-06-14T23:00")        // 3h
        let bStart = a + 3 * 3600 + 30 * 60      // 30 min wake gap (< 60) then resume
        let blocks = [
            SleepStageTotals.NightBlock(start: a,      end: a + 3 * 3600),
            SleepStageTotals.NightBlock(start: bStart, end: bStart + 3 * 3600),
        ]
        let bridged = SleepStageTotals.bridgeAdjacent(blocks)
        XCTAssertEqual(bridged.count, 1, "a < 60 min wake gap bridges the two runs into one block")
        XCTAssertEqual(bridged[0].start, a)
        XCTAssertEqual(bridged[0].end, bStart + 3 * 3600)
        // A >= 60 min gap must NOT bridge.
        let cStart = a + 3 * 3600 + 75 * 60
        let unbridged = SleepStageTotals.bridgeAdjacent([
            SleepStageTotals.NightBlock(start: a,      end: a + 3 * 3600),
            SleepStageTotals.NightBlock(start: cStart, end: cStart + 3 * 3600),
        ])
        XCTAssertEqual(unbridged.count, 2, "a >= 60 min wake gap stays two blocks")
    }

    /// Cross-midnight onset: a 23:30 onset (just before midnight) is overnight and its midpoint math wraps
    /// correctly, so it out-scores a midday nap.
    func testCrossMidnightOnsetScoresAsNight() {
        let night = ts525("2026-06-14T23:30")  // 6h crossing midnight, mid 02:30
        let nap   = ts525("2026-06-15T13:00")  // 1h
        let blocks = [
            SleepStageTotals.NightBlock(start: nap,   end: nap   + 1 * 3600),
            SleepStageTotals.NightBlock(start: night, end: night + 6 * 3600),
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 1)
    }

    /// Circular-time correctness: 23:30 and 00:30 are an HOUR apart, not 23h.
    func testCircularDistanceWrapsMidnight() {
        XCTAssertEqual(SleepStageTotals.circularDistanceSec(sod("23:30"), sod("00:30")), 3600)
        XCTAssertEqual(SleepStageTotals.circularDistanceSec(sod("00:30"), sod("23:30")), 3600)
        XCTAssertEqual(SleepStageTotals.circularDistanceSec(sod("12:00"), sod("00:00")), 43200, "antipodal = 12h")
        XCTAssertEqual(SleepStageTotals.circularDistanceSec(sod("03:30"), sod("03:30")), 0)
    }

    // MARK: - #547 habitual midsleep (learned timing)

    /// A day key from a midpoint, for synthesizing per-day history.
    private func dayKey(_ ts: Int) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Cold-start: fewer than minDays of history → nil (the scorer then uses the overnight band).
    func testHabitualMidsleepNilOnColdStart() {
        var hist: [SleepStageTotals.HistoryBlock] = []
        for d in 0..<5 {                                   // only 5 days, < 14
            let onset = ts525("2026-06-01T23:00") + d * 86_400
            hist.append(.init(start: onset, end: onset + 7 * 3600, dayKey: dayKey(onset)))
        }
        XCTAssertNil(SleepStageTotals.habitualMidsleepSec(hist, offsetSec: 0),
                     "too little history → nil (cold-start)")
    }

    /// A regular sleeper: 20 nights at 23:00→06:00 (mid 02:30) → habitual midsleep ≈ 02:30. Each night
    /// shares its day key with a short same-day nap; longest-per-day must pick the night, so naps never
    /// pull the learned midpoint.
    func testHabitualMidsleepLearnsRegularTiming() throws {
        var hist: [SleepStageTotals.HistoryBlock] = []
        for d in 0..<20 {
            let onset = ts525("2026-06-01T23:00") + d * 86_400
            let key = "night-\(d)"   // explicit key so the night + its nap share a day, deterministically
            hist.append(.init(start: onset, end: onset + 7 * 3600, dayKey: key))            // 7h night
            let napOnset = onset - 8 * 3600                                                 // a 15:00 nap
            hist.append(.init(start: napOnset, end: napOnset + 1 * 3600, dayKey: key))      // 1h nap, same key
        }
        let mid = try XCTUnwrap(SleepStageTotals.habitualMidsleepSec(hist, offsetSec: 0))
        XCTAssertEqual(mid, sod("02:30"), "midsleep is the night's midpoint, naps excluded by longest-per-day")
    }

    /// Circular learning across midnight: nights straddling 00:00 (e.g. mids at 23:30 and 00:30) average
    /// to ~midnight, NOT to noon (which a naive arithmetic mean would give).
    func testHabitualMidsleepCircularAcrossMidnight() throws {
        var hist: [SleepStageTotals.HistoryBlock] = []
        for d in 0..<16 {
            // Alternate the midpoint either side of midnight: half at 23:30, half at 00:30.
            let onset = (d % 2 == 0) ? ts525("2026-06-01T20:00") : ts525("2026-06-01T21:00")
            let shifted = onset + d * 86_400                // 7h block → mid 23:30 or 00:30
            hist.append(.init(start: shifted, end: shifted + 7 * 3600, dayKey: dayKey(shifted)))
        }
        let mid = try XCTUnwrap(SleepStageTotals.habitualMidsleepSec(hist, offsetSec: 0))
        // Circular mean of 23:30 and 00:30 is 00:00 (±a few seconds of rounding).
        let dist = SleepStageTotals.circularDistanceSec(mid, sod("00:00"))
        XCTAssertLessThan(dist, 120, "circular mean of 23:30/00:30 ≈ midnight, not noon")
    }

    // MARK: - #547 Caveat A: the UI selector and the engine selector agree for a SHIFT sleeper

    /// THE bug this fix closes: a shift/late sleeper whose LEARNED habitual midsleep is ~14:00. On a day
    /// with BOTH an afternoon main sleep AND a shorter overnight block, the engine (which threads the
    /// learned habitual into `analyzeDay`) tracked the AFTERNOON block, but the Sleep tab hero — which used
    /// to call the selector with NO habitual (cold-start band only) — picked the OVERNIGHT block, breaking
    /// the #525/#547 "hero == analytics total" invariant for that user.
    ///
    /// This replays both seams over the EXACT same blocks: (1) the LEARNED habitual is computed from this
    /// shift-sleeper's history via the same `habitualMidsleepSec` pure function the engine and the new
    /// `Repository.habitualMidsleepSec` both use; (2) `mainNightIndex(..., habitualMidsleepSec:)` — the
    /// single shared selector both `mainNightSession` (UI, now fed the learned habitual) and `analyzeDay`
    /// (engine) call — resolves to the SAME index. With the fix the UI passes the learned habitual, so it
    /// picks the AFTERNOON block, matching the engine; the asserted contrast is the OLD cold-start UI call
    /// (nil habitual) picking the overnight block — the divergence the fix removes.
    func testShiftSleeperUIAndEngineSelectorPickSameAfternoonBlock() throws {
        // 1) Learn the habitual from ~20 afternoon nights (onset 12:00, 6h → mid 15:00).
        var hist: [SleepStageTotals.HistoryBlock] = []
        for d in 0..<20 {
            let onset = ts525("2026-06-01T12:00") + d * 86_400
            hist.append(.init(start: onset, end: onset + 6 * 3600, dayKey: dayKey(onset)))
        }
        let habitual = try XCTUnwrap(SleepStageTotals.habitualMidsleepSec(hist, offsetSec: 0),
                                     "20 afternoon nights clear the cold-start threshold")
        XCTAssertEqual(SleepStageTotals.circularDistanceSec(habitual, sod("15:00")) < 120, true,
                       "learned midsleep is ~15:00 for this shift sleeper")

        // 2) A target day with BOTH an afternoon main sleep (mid ~15:00, on the habitual) AND a shorter
        //    overnight block. Index 0 = overnight, index 1 = afternoon (input order is irrelevant to the pick).
        let overnight = ts525("2026-06-21T23:00")        // 5h overnight, mid ~01:30 (far from 15:00)
        let afternoon = ts525("2026-06-21T12:00")        // 6h afternoon, mid 15:00 (on the habitual)
        let blocks = [
            SleepStageTotals.NightBlock(start: overnight, end: overnight + 5 * 3600),
            SleepStageTotals.NightBlock(start: afternoon, end: afternoon + 6 * 3600),
        ]

        // The shared selector WITH the learned habitual (what BOTH the UI hero AND the engine now use) →
        // the afternoon block. This is the byte-identical call both seams make.
        let withHabitual = try XCTUnwrap(
            SleepStageTotals.mainNightIndex(blocks, offsetSec: 0, habitualMidsleepSec: habitual))
        XCTAssertEqual(withHabitual, 1,
                       "with the learned ~15:00 habitual, the afternoon block is the main night (engine + UI agree)")

        // The OLD cold-start UI call (nil habitual) diverged — it picked the overnight block. This is the
        // exact bug Caveat A removes by feeding the same learned habitual to the UI selector.
        let coldStart = try XCTUnwrap(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0))
        XCTAssertEqual(coldStart, 0,
                       "cold-start band picks the overnight block — the pre-fix UI/engine divergence")
        XCTAssertNotEqual(withHabitual, coldStart,
                          "the learned habitual is exactly what makes the UI agree with the engine")
    }

    // MARK: - #547 Caveat B: circularMeanSec degenerate-vector guard

    /// Antipodal midpoints (12h apart) have a near-zero resultant vector, so `atan2` returns a meaningless
    /// (and potentially cross-platform-divergent) direction. The guard returns nil so `habitualMidsleepSec`
    /// falls back to cold-start rather than emit a bogus anchor. Here: 8 midpoints at 00:00 + 8 at 12:00.
    func testCircularMeanReturnsNilForAntipodalMidpoints() {
        let secs = (0..<8).flatMap { _ in [sod("00:00"), sod("12:00")] }   // 16 values, perfectly antipodal
        XCTAssertNil(SleepStageTotals.circularMeanSec(secs),
                     "antipodal midpoints → degenerate resultant → nil (no meaningless angle)")
    }

    /// The guard also fires end-to-end: a 16-day history split evenly between two antipodal sleep times
    /// (so the per-day midpoints are 12h apart) clears the day-count threshold but yields nil, NOT a bogus
    /// midnight/noon anchor — so the scorer falls back to the cold-start band identically on both platforms.
    func testHabitualMidsleepNilWhenLearnedTimingIsAntipodal() {
        var hist: [SleepStageTotals.HistoryBlock] = []
        for d in 0..<16 {
            // Even days: a night centered 00:00. Odd days: a sleep centered 12:00. Distinct day keys.
            let onset = (d % 2 == 0) ? ts525("2026-06-01T20:30") : ts525("2026-06-01T08:30")
            let shifted = onset + d * 86_400               // 7h block → mid 00:00 or 12:00
            hist.append(.init(start: shifted, end: shifted + 7 * 3600, dayKey: dayKey(shifted)))
        }
        XCTAssertNil(SleepStageTotals.habitualMidsleepSec(hist, offsetSec: 0),
                     "antipodal learned timing → nil (cold-start fallback), not a meaningless anchor")
    }

    // MARK: - #547 wire-through: effective (edited) onset crosses the overnight boundary (audit finding C / #8)

    /// The finding-C case: a block's DETECTED onset and its user-CORRECTED (effective) onset fall on
    /// opposite sides of the overnight boundary. The seam must score on the EFFECTIVE onset (what the
    /// Sleep tab shows), not the immutable detected key, so the seam and the UI pick the same block. The
    /// fixture is built so the two onset maps DISAGREE: the main block (300 asleep) is detected at 09:30
    /// (daytime → 0 bonus) but EDITED to start 22:30 (overnight → ~75 min bonus, taking it to ~375). A
    /// longer 340-asleep nap with no bonus then loses to the effective-onset main (375>340) but BEATS the
    /// detected-onset main (340>300). So the chosen block flips with the onset used — proving the fix.
    func testEditedOnsetCrossingBoundaryIsScoredOnTheEffectiveOnset() throws {
        let detectedStart = ts525("2026-06-15T09:30")   // detected as a daytime onset (bonus 0)
        let effectiveStart = ts525("2026-06-14T22:30")  // user moved bedtime back → overnight (bonus ~75)
        let napStart = ts525("2026-06-15T15:00")         // far from the band center (bonus 0)
        let mainStages = #"{"awake":0,"light":150,"deep":80,"rem":70}"#   // 300 asleep
        let napStages  = #"{"awake":0,"light":170,"deep":90,"rem":80}"#   // 340 asleep (longer)
        let blocksByStages = [(startTs: detectedStart, stagesJSON: mainStages),
                              (startTs: napStart,      stagesJSON: napStages)]
        // Effective-onset map (correct, finding-C fix): main scored at 22:30 → bonus lifts it over the nap.
        let onEffective: [Int: Int] = [detectedStart: effectiveStart, napStart: napStart]
        let idxEff = SleepStageTotals.mainNightIndexByStages(blocksByStages, onsetByStart: onEffective, offsetSec: 0)
        XCTAssertEqual(idxEff, 0, "effective (edited) overnight onset earns the bonus, so the main block wins")
        // Wrong (detected-onset) map: main is daytime → 0 bonus → the longer nap (340) wins instead.
        let onDetected: [Int: Int] = [detectedStart: detectedStart, napStart: napStart]
        let idxDet = SleepStageTotals.mainNightIndexByStages(blocksByStages, onsetByStart: onDetected, offsetSec: 0)
        XCTAssertEqual(idxDet, 1, "detected onset misses the bonus → the longer nap mis-wins (the finding-C bug)")
        // End-to-end through the seam: with the effective onset the day total is the MAIN block's 300.
        let rEff = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: detectedStart, stagesJSON: mainStages),
                       (startTs: napStart,      stagesJSON: napStages)],
            edited: [detectedStart: mainStages],
            onsetByStart: onEffective, offsetSec: 0))
        XCTAssertTrue(rEff.editApplied)
        XCTAssertEqual(rEff.sleep.totalSleepMin, 300, accuracy: 0.001,
                       "seam scores on the EFFECTIVE onset, so the corrected overnight block is the day total")
    }

    /// The habitual midsleep threads through the seam: with a learned AFTERNOON habitual, an afternoon
    /// sleep becomes the day's headline total over a shorter overnight block, exactly as the bare selector
    /// does. Proves `dailyAggregateHonoringEdits` honors `habitualMidsleepSec`.
    func testHonoringEditsHonorsHabitualMidsleep() throws {
        let habitual = sod("14:00")
        let nightStart = ts525("2026-06-14T23:00")  // 4h overnight, mid 01:00
        let dayStart   = ts525("2026-06-15T11:00")  // 6h afternoon, mid 14:00 (on the habitual)
        let nightStages = #"{"awake":0,"light":120,"deep":60,"rem":60}"#  // 240 asleep
        let dayStages   = #"{"awake":0,"light":200,"deep":80,"rem":80}"#  // 360 asleep
        let detected = [(startTs: nightStart, stagesJSON: nightStages),
                        (startTs: dayStart,   stagesJSON: dayStages)]
        let onset = [nightStart: nightStart, dayStart: dayStart]
        // With the afternoon habitual the longer, on-timing afternoon block is the day total.
        let rHab = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: detected, edited: [dayStart: dayStages],
            onsetByStart: onset, offsetSec: 0, habitualMidsleepSec: habitual))
        XCTAssertEqual(rHab.sleep.totalSleepMin, 360, accuracy: 0.001,
                       "afternoon habitual → the on-timing afternoon block is the headline total")
    }

    /// `AnalyticsEngine.analyzeDay` threads `habitualMidsleepSec` into the selector. A real overnight
    /// detected night, scored with an afternoon habitual, still produces a sleep metric (the single
    /// detected block is always the main night); the point is the arg compiles + flows without breaking
    /// the cold-start contract. Cold-start (nil) and an aligned habitual must both resolve the night.
    func testAnalyzeDayAcceptsHabitualMidsleepWithoutBreakingColdStart() {
        let day = "2021-06-15"
        let n = night(endDay: day, hours: 7)
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
        let cold = AnalyticsEngine.analyzeDay(day: day, hr: n.hr, rr: n.rr, gravity: n.gravity,
                                              profile: profile)
        let withHabitual = AnalyticsEngine.analyzeDay(day: day, hr: n.hr, rr: n.rr, gravity: n.gravity,
                                                      profile: profile, habitualMidsleepSec: 3 * 3600 + 1800)
        XCTAssertNotNil(cold.daily.totalSleepMin)
        XCTAssertNotNil(withHabitual.daily.totalSleepMin)
        // One detected night → the same main block either way; the habitual arg must not change a
        // single-night day's total.
        XCTAssertEqual(cold.daily.totalSleepMin!, withHabitual.daily.totalSleepMin!, accuracy: 0.001)
    }

    // MARK: - REAL fixture replay (evidence on recorded data, not synthetic) (#547)

    /// Parse a "UTC±HH:MM" Whoop `Cycle timezone` to seconds east of UTC — the same convention
    /// `StrandImport.WhoopTime.tzOffsetMinutes` uses (StrandAnalytics can't depend on StrandImport, so
    /// the two columns this replay needs are parsed here with the identical rule).
    private func whoopTzOffsetSec(_ raw: String) -> Int {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.uppercased().hasPrefix("UTC") { s = String(s.dropFirst(3)) }
        var sign = 1
        if s.hasPrefix("+") { s.removeFirst() } else if s.hasPrefix("-") { sign = -1; s.removeFirst() }
        let p = s.split(separator: ":")
        let h = Int(p.first ?? "0") ?? 0, m = p.count > 1 ? (Int(p[1]) ?? 0) : 0
        return sign * (h * 60 + m) * 60
    }

    /// Parse a Whoop CSV "YYYY-MM-DD HH:MM:SS" local wall-clock into a UTC unix timestamp, interpreting
    /// the string in the given offset — the same instant `WhoopTime.parse` would return.
    private func whoopTs(_ wall: String, offsetSec: Int) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: offsetSec)!
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return Int(f.date(from: wall)!.timeIntervalSince1970)
    }

    /// EVIDENCE on REAL data: the recorded WHOOP `sleeps.csv` fixture
    /// (Packages/StrandImport/Tests/StrandImportTests/Resources/sleeps.csv) holds a genuine multi-session
    /// day — 2024-01-02, tz UTC+01:00 — with a real overnight sleep (Sleep onset 2024-01-01 23:15 → Wake
    /// 06:30, Nap=false, 420 asleep / 455 in-bed) AND a real daytime nap (14:00 → 14:25, Nap=true, 25 min).
    /// The obviously-correct human answer is that the OVERNIGHT block is the main night and the 25-min
    /// afternoon block is the nap. This replays the production `mainNightIndex` selector over those exact
    /// recorded sessions (rows copied verbatim from the fixture) and asserts the overnight wins, so we have
    /// evidence the new learned-timing scorer behaves on real export data, not just synthetic blocks.
    /// (Cold-start path: no learned habitual yet, so the overnight-band bonus applies.)
    func testRealWhoopSleepsCsvFixturePicksOvernightAsMainNight() throws {
        // Verbatim rows from the fixture (cycle timezone, sleep onset, wake onset, isNap).
        let tz = whoopTzOffsetSec("UTC+01:00")
        XCTAssertEqual(tz, 3600, "UTC+01:00 → +3600s east")

        let nightOnset = whoopTs("2024-01-01 23:15:00", offsetSec: tz)   // Nap=false
        let nightWake  = whoopTs("2024-01-02 06:30:00", offsetSec: tz)
        let napOnset   = whoopTs("2024-01-02 14:00:00", offsetSec: tz)   // Nap=true
        let napWake    = whoopTs("2024-01-02 14:25:00", offsetSec: tz)

        // Sanity on the recorded spans: a ~7h15m overnight and a 25-min nap.
        XCTAssertEqual((nightWake - nightOnset) / 60, 435, "recorded overnight clock span ≈ 7h15m")
        XCTAssertEqual((napWake - napOnset) / 60, 25, "recorded nap clock span = 25 min")

        // Build the candidate blocks IN FILE ORDER (overnight row first, nap row second — as the CSV lists
        // them) and run the real selector with the fixture's true tz offset, cold-start (nil habitual).
        let blocks = [
            SleepStageTotals.NightBlock(start: nightOnset, end: nightWake),
            SleepStageTotals.NightBlock(start: napOnset,   end: napWake),
        ]
        let idx = try XCTUnwrap(SleepStageTotals.mainNightIndex(blocks, offsetSec: tz),
                                "selector must resolve a main night on the real fixture day")
        XCTAssertEqual(idx, 0, "the recorded overnight sleep is the main night; the 25-min afternoon block is the nap")

        // Order-independence: reverse the candidates and the SAME physical block must still win.
        let reversed = [blocks[1], blocks[0]]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(reversed, offsetSec: tz), 1,
                       "the pick is the overnight block regardless of input order")

        // isNap = \"not the chosen main block\": exactly one block is the main, the other is a nap.
        XCTAssertEqual(blocks.indices.filter { $0 != idx }, [1],
                       "the afternoon 25-min block is classified as the nap")
    }

    // MARK: - Selection reason (explainability — WHY this block is the main night) (spec 2026-06-20)

    /// `mainNightSelection.index` must always equal `mainNightIndex` (same score, same tie-break) — the
    /// enriched call is the SAME pick, just annotated. Replays it over the realistic cold-start sweep.
    func testSelectionIndexAlwaysMatchesMainNightIndex() {
        let nightOnsets = ["2026-06-14T22:00", "2026-06-14T23:00", "2026-06-15T00:00"]
        let nightHours = [4, 6, 8]
        let napOnsets = ["2026-06-15T08:00", "2026-06-15T13:00", "2026-06-15T19:00"]
        let napMins = [30, 90, 180]
        for no in nightOnsets {
            for nh in nightHours {
                let nStart = ts525(no)
                for po in napOnsets {
                    for pm in napMins {
                        let pStart = ts525(po)
                        let blocks = [
                            SleepStageTotals.NightBlock(start: pStart, end: pStart + pm * 60),
                            SleepStageTotals.NightBlock(start: nStart, end: nStart + nh * 3600),
                        ]
                        let idx = SleepStageTotals.mainNightIndex(blocks, offsetSec: 0)
                        let sel = SleepStageTotals.mainNightSelection(blocks, offsetSec: 0)
                        XCTAssertEqual(sel?.index, idx, "enriched selection must pick the same block as mainNightIndex")
                    }
                }
            }
        }
    }

    /// Reason branch ONLY-BLOCK: a single block carries the `onlyBlock` reason and its own asleep span.
    func testSelectionReasonOnlyBlock() throws {
        let nap = ts525("2026-06-15T13:00")
        let sel = try XCTUnwrap(SleepStageTotals.mainNightSelection(
            [SleepStageTotals.NightBlock(start: nap, end: nap + 40 * 60)], offsetSec: 0))
        XCTAssertEqual(sel.index, 0)
        XCTAssertEqual(sel.reason, .onlyBlock)
        XCTAssertEqual(sel.asleepSeconds, 40 * 60)
        XCTAssertEqual(sel.asleepMinutes, 40, accuracy: 0.001, "{DUR} fills from the chosen block's asleep")
    }

    /// Reason branch LONGEST (cold-start): no learned habitual, the longest block wins on duration alone,
    /// so the reason is plain `longest` even though it sits in the overnight band (cold-start = no habitual).
    func testSelectionReasonLongestColdStart() throws {
        let night = ts525("2026-06-14T23:00")   // 7h overnight, the longest
        let nap   = ts525("2026-06-15T13:00")   // 1h daytime nap
        let blocks = [
            SleepStageTotals.NightBlock(start: nap,   end: nap   + 1 * 3600),
            SleepStageTotals.NightBlock(start: night, end: night + 7 * 3600),
        ]
        let sel = try XCTUnwrap(SleepStageTotals.mainNightSelection(blocks, offsetSec: 0)) // nil habitual
        XCTAssertEqual(sel.index, 1, "the 7h overnight block is the main night")
        XCTAssertEqual(sel.reason, .longest, "cold-start (no learned habitual) → plain longest, never near-usual")
        XCTAssertEqual(sel.asleepSeconds, 7 * 3600)
    }

    /// Reason branch LONGEST (learned habitual present but chosen block OUTSIDE the bonus window): the
    /// longest block wins on duration and earns NO meaningful bonus (>5h circular from the habitual), so
    /// it is plain `longest`, not `longestNearUsual`.
    func testSelectionReasonLongestWhenLongestIsOutsideBonusWindow() throws {
        let habitual = sod("03:00")               // a normal night sleeper
        // The longest block is a 7h AFTERNOON sleep (mid 15:30) — >5h circular from 03:00 → bonus 0.
        let afternoon = ts525("2026-06-15T12:00") // 7h afternoon, mid 15:30, bonus 0, the longest
        let night     = ts525("2026-06-14T23:00") // 4h overnight, mid 01:00, full bonus 90 → 330
        let blocks = [
            SleepStageTotals.NightBlock(start: night,     end: night     + 4 * 3600), // 240 + 90 = 330
            SleepStageTotals.NightBlock(start: afternoon, end: afternoon + 7 * 3600), // 420 + 0  = 420 wins
        ]
        let sel = try XCTUnwrap(SleepStageTotals.mainNightSelection(blocks, offsetSec: 0,
                                                                    habitualMidsleepSec: habitual))
        XCTAssertEqual(sel.index, 1, "the 7h afternoon block wins on raw duration (420 > 330)")
        XCTAssertEqual(sel.reason, .longest,
                       "chosen IS the longest but earns no bonus (outside the window) → plain longest")
        XCTAssertEqual(sel.asleepSeconds, 7 * 3600)
    }

    /// Reason branch LONGEST-NEAR-USUAL: the chosen block is the longest by duration AND a learned habitual
    /// exists AND the block earns a meaningful alignment bonus. Duration would have picked it; timing agrees.
    func testSelectionReasonLongestNearUsual() throws {
        let habitual = sod("03:00")               // normal night sleeper, habitual midsleep 03:00
        let night = ts525("2026-06-14T23:00")     // 7h overnight, mid ~02:30 (inside the bonus window), longest
        let nap   = ts525("2026-06-15T13:00")     // 1h daytime nap, far from 03:00 (bonus 0)
        let blocks = [
            SleepStageTotals.NightBlock(start: nap,   end: nap   + 1 * 3600),
            SleepStageTotals.NightBlock(start: night, end: night + 7 * 3600),
        ]
        let sel = try XCTUnwrap(SleepStageTotals.mainNightSelection(blocks, offsetSec: 0,
                                                                    habitualMidsleepSec: habitual))
        XCTAssertEqual(sel.index, 1, "the 7h overnight block is the longest and on the habitual")
        XCTAssertEqual(sel.reason, .longestNearUsual,
                       "longest by duration AND a learned habitual with a meaningful bonus → near-usual")
        XCTAssertEqual(sel.asleepSeconds, 7 * 3600)
    }

    /// Reason branch ALIGNED-TO-USUAL: the chosen block is NOT the longest; the alignment bonus flipped the
    /// pick away from the longer block toward this shorter, well-timed one. (= testHabitualAlignedShorter…)
    func testSelectionReasonAlignedToUsual() throws {
        let habitual = sod("03:00")               // normal sleeper
        let afternoon = ts525("2026-06-15T13:00") // 5h afternoon = 300, mid 15:30, bonus 0, the LONGEST
        let night     = ts525("2026-06-15T01:00") // 4h at habitual = 240, mid 03:00, bonus 90 → 330 wins
        let blocks = [
            SleepStageTotals.NightBlock(start: afternoon, end: afternoon + 5 * 3600),
            SleepStageTotals.NightBlock(start: night,     end: night     + 4 * 3600),
        ]
        let sel = try XCTUnwrap(SleepStageTotals.mainNightSelection(blocks, offsetSec: 0,
                                                                    habitualMidsleepSec: habitual))
        XCTAssertEqual(sel.index, 1, "the habitual-aligned 4h night wins over the longer 5h afternoon")
        XCTAssertEqual(sel.reason, .alignedToUsual,
                       "the chosen block is NOT the longest; the alignment bonus flipped the pick")
        XCTAssertEqual(sel.asleepSeconds, 4 * 3600, "{DUR} is the CHOSEN (shorter, aligned) block's span")
    }

    /// Aligned-to-usual also covers the equal-duration case: two equal-length blocks, the habitual-aligned
    /// one wins on bonus even though duration-only (earlier-onset tie-break) would have picked the other.
    func testSelectionReasonAlignedToUsualOnEqualDurations() throws {
        let habitual = sod("14:00")               // a daytime/shift sleeper
        let night     = ts525("2026-06-14T23:00") // 6h overnight, mid 02:00 (far from 14:00) — earlier onset
        let afternoon = ts525("2026-06-15T11:00") // 6h afternoon, mid 14:00 (on the habitual) — later onset
        let blocks = [
            SleepStageTotals.NightBlock(start: night,     end: night     + 6 * 3600),
            SleepStageTotals.NightBlock(start: afternoon, end: afternoon + 6 * 3600),
        ]
        let sel = try XCTUnwrap(SleepStageTotals.mainNightSelection(blocks, offsetSec: 0,
                                                                    habitualMidsleepSec: habitual))
        XCTAssertEqual(sel.index, 1, "equal duration → the habitual-aligned afternoon block wins on bonus")
        XCTAssertEqual(sel.reason, .alignedToUsual,
                       "duration-only (earlier onset) would have picked the night; alignment flipped it")
    }

    // MARK: - Selection reason via the STAGES seam (decoded asleep minutes drive {DUR}) (spec 2026-06-20)

    /// The stages-path selection: index matches `mainNightIndexByStages`, the reason is decided on DECODED
    /// asleep minutes, and `asleepSeconds` is the chosen block's decoded asleep span (not clock span).
    func testSelectionByStagesReasonAndDecodedDuration() throws {
        let nightStart = ts525("2026-06-14T23:00")
        let napStart   = ts525("2026-06-15T14:00")
        let nightStages = #"{"awake":24,"light":214,"deep":82,"rem":96}"#   // 392 min asleep (longest)
        let napStages   = #"{"awake":2,"light":30,"deep":10,"rem":8}"#      // 48 min asleep
        let blocks = [(startTs: napStart,   stagesJSON: napStages),
                      (startTs: nightStart, stagesJSON: nightStages)]
        let onset = [napStart: napStart, nightStart: nightStart]
        let idx = SleepStageTotals.mainNightIndexByStages(blocks, onsetByStart: onset, offsetSec: 0)
        let sel = try XCTUnwrap(SleepStageTotals.mainNightSelectionByStages(
            blocks, onsetByStart: onset, offsetSec: 0))                     // nil habitual → cold-start
        XCTAssertEqual(sel.index, idx, "stages selection index matches mainNightIndexByStages")
        XCTAssertEqual(sel.index, 1, "the 392-min overnight block is the main night")
        XCTAssertEqual(sel.reason, .longest, "cold-start → plain longest")
        XCTAssertEqual(sel.asleepSeconds, 392 * 60, "{DUR} is the DECODED asleep span, not clock span")
        XCTAssertEqual(sel.asleepMinutes, 392, accuracy: 0.001)
    }

    /// Stages seam, ALIGNED-TO-USUAL: a learned afternoon habitual flips the pick to the shorter, on-timing
    /// afternoon block, and the reason reflects that the bonus (not duration) decided it.
    func testSelectionByStagesReasonAlignedToUsual() throws {
        let habitual = sod("14:00")
        let nightStart = ts525("2026-06-14T23:00")  // 4h overnight, mid 01:00 → 240 asleep
        let dayStart   = ts525("2026-06-15T13:00")  // afternoon, mid 15:00 (1h from habitual) → 240 asleep, +bonus
        let nightStages = #"{"awake":0,"light":300,"deep":80,"rem":40}"#   // 420 asleep (LONGEST)
        let dayStages   = #"{"awake":0,"light":120,"deep":60,"rem":60}"#   // 240 asleep, but aligned → +90
        let blocks = [(startTs: nightStart, stagesJSON: nightStages),
                      (startTs: dayStart,   stagesJSON: dayStages)]
        let onset = [nightStart: nightStart, dayStart: dayStart]
        // night: 420 + bonus(mid 01:00 vs 14:00 → 0) = 420; day: 240 + bonus(~14:30 vs 14:00 → 90) = 330.
        // Here the LONGER night still wins (420 > 330) → reason longest. Verify, then shorten the night so
        // alignment flips it.
        let selA = try XCTUnwrap(SleepStageTotals.mainNightSelectionByStages(
            blocks, onsetByStart: onset, offsetSec: 0, habitualMidsleepSec: habitual))
        XCTAssertEqual(selA.index, 0)
        XCTAssertEqual(selA.reason, .longest, "longest night wins on duration; habitual far from it → no bonus")

        // Now make the night SHORTER than the aligned afternoon's score so alignment flips the pick.
        let shortNight = #"{"awake":0,"light":120,"deep":60,"rem":60}"#    // 240 asleep, mid 01:00, bonus 0
        let blocks2 = [(startTs: nightStart, stagesJSON: shortNight),       // 240
                       (startTs: dayStart,   stagesJSON: dayStages)]        // 240 + 90 = 330 wins
        let sel2 = try XCTUnwrap(SleepStageTotals.mainNightSelectionByStages(
            blocks2, onsetByStart: onset, offsetSec: 0, habitualMidsleepSec: habitual))
        XCTAssertEqual(sel2.index, 1, "equal asleep → the aligned afternoon block wins on bonus")
        XCTAssertEqual(sel2.reason, .alignedToUsual, "alignment, not duration, decided the flipped pick")
        XCTAssertEqual(sel2.asleepSeconds, 240 * 60, "decoded asleep of the chosen afternoon block")
    }

    /// Stages seam, ONLY-BLOCK: a single decoded block → onlyBlock with its decoded asleep span.
    func testSelectionByStagesReasonOnlyBlock() throws {
        let nap = ts525("2026-06-15T13:00")
        let sel = try XCTUnwrap(SleepStageTotals.mainNightSelectionByStages(
            [(startTs: nap, stagesJSON: #"{"awake":2,"light":24,"deep":8,"rem":6}"#)],
            onsetByStart: [nap: nap], offsetSec: 0))
        XCTAssertEqual(sel.reason, .onlyBlock)
        XCTAssertEqual(sel.asleepSeconds, 38 * 60, "decoded asleep = 24+8+6 = 38 min")
    }

    // MARK: - #561 biphasic gap-bridge (mainNightGroupIndices)

    func testGroupIndicesBridgesTwoAdjacentFragments() throws {
        // Two overnight fragments split by a 30-min wake gap (< 60-min bridge) → one group of BOTH.
        let a = ts525("2026-06-14T23:00")
        let aEnd = a + 3 * 3600                     // 23:00 → 02:00
        let b = aEnd + 30 * 60                      // 02:30 (30-min gap < gapBridgeMaxMin)
        let blocks = [
            SleepStageTotals.NightBlock(start: a, end: aEnd),
            SleepStageTotals.NightBlock(start: b, end: b + 3 * 3600),   // 02:30 → 05:30
        ]
        let group = try XCTUnwrap(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: 0))
        XCTAssertEqual(group, [0, 1], "a <60-min wake gap bridges both fragments into the main-night group")
    }

    func testGroupIndicesDoesNotBridgeLongGap() throws {
        // A 5 h wake gap is NOT a biphasic interruption — the second block is a separate (daytime) sleep,
        // so the group is just the single winning block (the longer overnight one).
        let a = ts525("2026-06-14T23:00")
        let aEnd = a + 5 * 3600                     // 23:00 → 04:00 (5h overnight, the main night)
        let b = aEnd + 5 * 3600                     // 09:00 (5h gap >> 60-min bridge)
        let blocks = [
            SleepStageTotals.NightBlock(start: a, end: aEnd),
            SleepStageTotals.NightBlock(start: b, end: b + 2 * 3600),   // 2h daytime nap
        ]
        let group = try XCTUnwrap(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: 0))
        XCTAssertEqual(group, [0], "a long wake gap is not bridged — only the main block is the group")
    }

    func testGroupIndicesSingleBlockMatchesBareSelector() throws {
        // No gap to bridge → the group is exactly the single block mainNightIndex would pick (no regression).
        let s = ts525("2026-06-15T00:00")
        let blocks = [SleepStageTotals.NightBlock(start: s, end: s + 7 * 3600)]
        XCTAssertEqual(try XCTUnwrap(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: 0)), [0])
        XCTAssertNil(SleepStageTotals.mainNightGroupIndices([], offsetSec: 0))
    }

    func testGroupIndicesBridgedNightOutscoresLoneNap() throws {
        // A biphasic main night (2h + gap + 2h = 4h bridged) must out-score a lone 3h daytime nap that,
        // un-bridged, would beat either 2h fragment alone — proving the bridge is what wins.
        let f1 = ts525("2026-06-14T23:00")
        let f1End = f1 + 2 * 3600                    // 23:00 → 01:00
        let f2 = f1End + 20 * 60                     // 01:20 (20-min gap)
        let f2End = f2 + 2 * 3600                    // → 03:20
        let nap = ts525("2026-06-15T13:00")          // daytime
        let blocks = [
            SleepStageTotals.NightBlock(start: f1,  end: f1End),
            SleepStageTotals.NightBlock(start: nap, end: nap + 3 * 3600),  // 3h lone nap
            SleepStageTotals.NightBlock(start: f2,  end: f2End),
        ]
        let group = try XCTUnwrap(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: 0))
        XCTAssertEqual(group.sorted(), [0, 2], "the bridged biphasic night wins, returning BOTH its fragments")
    }

    // MARK: - #861 a real overnight night split by a 60–90 min wake is ONE sleep, not nap + sleep

    /// The reported pattern (#861): one overnight sleep the detector left split into two fragments by a real
    /// mid-night wake of ~70 min, longer than the old 60-min `gapBridgeMaxMin`, so the later fragment lost the
    /// main-night pick and was LABELLED A NAP. The wider overnight night-tail bridge (≤ `nightTailBridgeMaxMin`,
    /// onset still in the overnight band) now folds both fragments into ONE main-night group, so neither part is
    /// a nap. Honest-data invariant: no stage is invented; the 70-min gap is later folded into AWAKE by the
    /// aggregate, not relabelled sleep.
    func testOvernightNightSplitBySeventyMinuteWakeMergesIntoOneSleepNotNap() throws {
        let a = ts525("2026-06-14T23:30")               // overnight onset
        let aEnd = a + 3 * 3600                          // 23:30 → 02:30
        let b = aEnd + 70 * 60                           // 03:40 onset (70-min wake gap; 60 ≤ gap < 90)
        let bEnd = b + 4 * 3600                          // 03:40 → 07:40 (the longer tail)
        let blocks = [
            SleepStageTotals.NightBlock(start: a, end: aEnd),
            SleepStageTotals.NightBlock(start: b, end: bEnd),
        ]
        // Before the fix a 70-min gap was NOT bridged, the 4h tail won, and the 3h head became a "nap".
        let group = try XCTUnwrap(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: 0))
        XCTAssertEqual(group.sorted(), [0, 1],
                       "a 60–90 min mid-night wake bridges both overnight fragments into one sleep (no nap)")
        // The wider bridge must NOT touch the bare `bridgeAdjacent` (its <60-min contract is unchanged): a
        // 70-min gap still leaves it two blocks, so the golden detector-side bridge tests stay byte-identical.
        XCTAssertEqual(SleepStageTotals.bridgeAdjacent(blocks).count, 2,
                       "the band-aware widening lives only in mainNightGroupIndices, not bridgeAdjacent")
    }

    /// The daytime guard the widening must NOT breach: a genuine afternoon nap with the SAME 70-min gap from the
    /// night's end stays its OWN block, because its onset is in the daytime band (not the overnight band the
    /// wider bridge requires). So a real nap is never folded into the night by the #861 fix.
    func testDaytimeNapWithSeventyMinuteGapStillStaysItsOwnBlock() throws {
        let night = ts525("2026-06-15T00:00")           // overnight
        let nightEnd = night + 6 * 3600                  // 00:00 → 06:00 (the main night)
        // A 70-min gap from the night's end lands the nap onset at 07:10, still inside the broad overnight
        // band [20:00, 11:00). To prove the DAYTIME guard, place the nap at a true daytime onset (13:00) and
        // confirm it is not bridged regardless of being the same day.
        let nap = ts525("2026-06-15T13:00")             // daytime onset → never a night-tail
        let blocks = [
            SleepStageTotals.NightBlock(start: night, end: nightEnd),
            SleepStageTotals.NightBlock(start: nap,   end: nap + 90 * 60),  // 1.5h afternoon nap
        ]
        let group = try XCTUnwrap(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: 0))
        XCTAssertEqual(group, [0], "a daytime-onset nap is never folded into the night by the wider bridge")
    }

    /// The upper guard: a wake gap at/over `nightTailBridgeMaxMin` (90 min) is NOT a mid-night wake, so it stays
    /// two blocks even for an overnight-band onset, so a genuinely separate early-morning sleep is not swallowed.
    func testOvernightGapAtOrAboveNinetyMinutesDoesNotBridge() throws {
        let a = ts525("2026-06-14T23:00")
        let aEnd = a + 3 * 3600                          // 23:00 → 02:00
        let b = aEnd + 95 * 60                           // 03:35 onset (95-min gap ≥ nightTailBridgeMaxMin)
        let blocks = [
            SleepStageTotals.NightBlock(start: a, end: aEnd),
            SleepStageTotals.NightBlock(start: b, end: b + 4 * 3600),
        ]
        let group = try XCTUnwrap(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: 0))
        XCTAssertEqual(group, [1], "a ≥90-min wake is not a night-tail; the blocks stay separate")
    }

    // MARK: - #561 stages-path seam sums the bridged group (analyzeDay parity)

    func testHonoringEditsSumsBiphasicGroup() throws {
        // Two overnight fragments (each ~3h25m of sleep) split by a short wake gap, fed through the
        // edit/recompute seam with onsets supplied → the daily total is the SUM of BOTH, not the longer one.
        let a = ts525("2026-06-14T23:00")
        // fragment A: 24+82+96 = 202 min sleep + 8 wake = 210 min in-bed → ends 02:30
        let aStages = #"{"awake":8,"light":24,"deep":82,"rem":96}"#
        let aInBedSec = 210 * 60
        let b = a + aInBedSec + 20 * 60               // 20-min wake gap < 60-min bridge
        // fragment B: 20+90+70 = 180 min sleep + 10 wake = 190 min in-bed
        let bStages = #"{"awake":10,"light":20,"deep":90,"rem":70}"#
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: a, stagesJSON: aStages), (startTs: b, stagesJSON: bStages)],
            edited: [:],
            onsetByStart: [a: a, b: b], offsetSec: 0))
        // Summed sleep = 202 + 180 = 382 min; the longer fragment alone would be only 202.
        XCTAssertEqual(r.sleep.totalSleepMin, 382, accuracy: 0.001,
                       "the seam SUMS the bridged biphasic group, not just the longest fragment")
        XCTAssertEqual(r.sleep.deepMin, 172, accuracy: 0.001)   // 82 + 90
    }

    private func night(endDay: String, hours: Int) -> (start: Int, end: Int, hr: [HRSample],
                                                       rr: [RRInterval], gravity: [GravitySample]) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let dayMidnight = Int(fmt.date(from: endDay)!.timeIntervalSince1970)
        let end = dayMidnight + 6 * 3600
        let start = end - hours * 3600
        var hr: [HRSample] = []; var rr: [RRInterval] = []; var grav: [GravitySample] = []
        for t in start..<end { hr.append(HRSample(ts: t, bpm: 50)); grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1)) }
        var toggle = false
        for t in stride(from: start, to: end, by: 2) {
            rr.append(RRInterval(ts: t, rrMs: toggle ? 1205 : 1195)); toggle.toggle()
        }
        return (start, end, hr, rr, grav)
    }
}
