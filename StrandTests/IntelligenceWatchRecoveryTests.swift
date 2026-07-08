import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins the Apple-Watch recovery fold (M1 "Watch as a device"): a watch-only user has apple-health DAILY
/// aggregates (SDNN HRV + resting HR) but no raw stream, so the raw-HR scoring loop never scores their days
/// and the import leaves `recovery: nil`. `IntelligenceEngine.watchRecoveries(appleRows:strapRecoveryDays:)`
/// folds the TRAILING SDNN+RHR history into the cross-lane `WatchRecovery` engine and writes a recovery +
/// confidence onto each day, staying nil/`.calibrating` until there's enough baseline (never a fabricated
/// number). Pure (no store) — the SAME logic `analyzeRecent` ships per day, tested directly like
/// `IntelligenceDaySourceTests`. WHOOP recovery still wins where both exist (the strap-day skip below).
final class IntelligenceWatchRecoveryTests: XCTestCase {

    /// Build a minimal apple-health daily row: only the fields the watch fold reads (day, avgHrv, restingHr)
    /// matter; everything else is the import's usual nils. `recovery: nil` is the state the import writes.
    private func appleRow(day: String, hrv: Double?, rhr: Int?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    /// Ten consecutive apple-health days (avgHrv + restingHr populated, recovery nil). With ~10 nights the
    /// trailing baseline crosses the engine's minimum, so the LATEST day comes out scored — non-nil recovery
    /// and a non-calibrating confidence — which is the whole point of the fold for a watch-only user.
    func testTenAppleDaysGiveLatestDayANonCalibratingRecovery() {
        let rows = (1...10).map { i in
            appleRow(day: String(format: "2026-06-%02d", i), hrv: 45.0, rhr: 52)
        }
        let scored = IntelligenceEngine.watchRecoveries(appleRows: rows)

        XCTAssertEqual(scored.count, 10)
        let latest = scored.last!
        XCTAssertEqual(latest.day, "2026-06-10")
        XCTAssertNotNil(latest.recovery, "the latest day should be scored once enough history exists")
        XCTAssertNotEqual(latest.confidence, .calibrating,
                          "enough nights of SDNN baseline → past the calibrating gate")
    }

    /// The earliest days have too little trailing history, so they stay honest: nil recovery, `.calibrating`.
    func testEarlyDaysStayCalibrating() {
        let rows = (1...10).map { i in
            appleRow(day: String(format: "2026-06-%02d", i), hrv: 45.0, rhr: 52)
        }
        let scored = IntelligenceEngine.watchRecoveries(appleRows: rows)

        // Day 1 has zero prior history; day 2 has one prior night — both well under the baseline minimum.
        XCTAssertNil(scored[0].recovery)
        XCTAssertEqual(scored[0].confidence, .calibrating)
        XCTAssertNil(scored[1].recovery)
        XCTAssertEqual(scored[1].confidence, .calibrating)
    }

    /// A day a strap already scored is SKIPPED, so WHOOP/computed recovery keeps winning (the source
    /// precedence prefers the strap; the watch fold never overwrites it with a lower-density number).
    func testStrapScoredDayIsSkipped() {
        let rows = (1...10).map { i in
            appleRow(day: String(format: "2026-06-%02d", i), hrv: 45.0, rhr: 52)
        }
        let strapDay = "2026-06-10"
        let scored = IntelligenceEngine.watchRecoveries(appleRows: rows, strapRecoveryDays: [strapDay])

        XCTAssertEqual(scored.count, 9, "the strap-owned day is not watch-scored")
        XCTAssertFalse(scored.contains { $0.day == strapDay })
    }

    /// The fold tolerates an out-of-order input (it sorts chronologically), so a later day still sees the
    /// full trailing baseline regardless of how the rows arrived from the store.
    func testUnorderedInputIsSortedBeforeFolding() {
        let ordered = (1...10).map { i in
            appleRow(day: String(format: "2026-06-%02d", i), hrv: 45.0, rhr: 52)
        }
        let scored = IntelligenceEngine.watchRecoveries(appleRows: ordered.shuffled())

        XCTAssertEqual(scored.map { $0.day }, ordered.map { $0.day })
        XCTAssertNotNil(scored.last!.recovery)
    }

    /// #823: the SAME source-only fold the wearable-import (Oura/Fitbit/Garmin/Health Connect) lane now uses
    /// to score Charge for an import-only day. The rows are import DailyMetric rows (HRV + RHR, recovery nil);
    /// with enough trailing history the latest import-only day comes out with a real Charge, so an
    /// imported-only user no longer sees a permanently blank ring. This is the engine the IntelligenceEngine
    /// wearable fold runs per source under `Repository.wearableImportSources`.
    func testImportOnlyDaysGetScoredCharge() {
        let importRows = (1...10).map { i in
            appleRow(day: String(format: "2026-06-%02d", i), hrv: 50.0, rhr: 50)
        }
        let scored = IntelligenceEngine.watchRecoveries(appleRows: importRows)
        let latest = scored.last!
        XCTAssertEqual(latest.day, "2026-06-10")
        XCTAssertNotNil(latest.recovery, "an import-only day with enough history must score a Charge (#823)")
        XCTAssertNotEqual(latest.confidence, .calibrating)
    }

    /// #823 honesty: a sparse import (only a couple of days) must NOT fabricate a Charge , it stays nil +
    /// calibrating, exactly like a cold-start strap. Only real, sufficient imported signal yields a score.
    func testSparseImportStaysCalibratingNeverFabricated() {
        let importRows = (1...3).map { i in
            appleRow(day: String(format: "2026-06-%02d", i), hrv: 50.0, rhr: 50)
        }
        let scored = IntelligenceEngine.watchRecoveries(appleRows: importRows)
        XCTAssertTrue(scored.allSatisfy { $0.recovery == nil })
        XCTAssertTrue(scored.allSatisfy { $0.confidence == .calibrating })
    }
}
