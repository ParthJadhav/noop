import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Bug #977 (iOS, WHOOP 5.0, live Bluetooth): "Rest score stuck 93 since forever."
///
/// Root cause under test: a LIVE WHOOP 5.0 streams standard 0x2A37 HR continuously, but
/// the accelerometer / gravity stream is only ever populated by the *history offload*
/// (Backfiller). When the overnight gravity has not been offloaded/decoded, the day reaches
/// the scoring loop with dense HR (so it clears IntelligenceEngine's `hr.count >= 200` gate
/// and recovery/Charge can still be computed from HR/HRV), but `SleepStager.detectSleep`
/// bails at `grav.count < 2 { return [] }` — so no sleep is matched, the DailyMetric carries
/// no `totalSleepMin`/`efficiency`, and `AnalyticsEngine.Rest.composite(daily:)` returns nil.
///
/// A nil composite means NO `sleep_performance` point is written for that night, so the Today
/// display falls back to the tail of the series (iOS `restSeries.last`, Android
/// `byDay.entries.maxByOrNull`) — the last night that WAS scored, e.g. 93 — and Rest is frozen
/// there forever while Charge keeps advancing.
///
/// These tests pin the mechanism. They are written to FAIL against a fix that makes a live-5.0
/// night produce SOME advancing Rest signal (whether by an HR-only fallback composite or by
/// forcing a gravity offload before scoring). Today they document the frozen state.
final class Live5RestFrozenTests: XCTestCase {

    private func hrStream(start: Int, durationS: Int, bpm: Int) -> [HRSample] {
        stride(from: 0, to: durationS, by: 1).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    /// A late-night start (02:00 UTC, tzOffset 0) so the window is unambiguously overnight and
    /// the daytime false-sleep guard is irrelevant to the outcome.
    private func nightStart() -> Int {
        let refMidnight = 1_749_513_600   // 2026-06-10 00:00:00 UTC
        return refMidnight + 2 * 3_600
    }

    // MARK: - Stage 1: no gravity ⇒ no sleep session (the direct BLE-live-5.0 shape)

    func testLive5NoGravityDenseHRDetectsNoSleep() {
        // 8 h of continuous, sleep-plausible HR (a real live-5.0 night streamed over 0x2A37),
        // but ZERO gravity because the accelerometer offload hasn't landed. detectSleep must
        // return no sessions — the strap streamed HR but not motion.
        let start = nightStart()
        let dur = 8 * 60 * 60
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: [])
        XCTAssertTrue(sessions.isEmpty,
                      "A live-5.0 night with HR but no offloaded gravity yields no sleep session")
    }

    // MARK: - Stage 2: no sleep ⇒ no Rest composite ⇒ no sleep_performance point

    /// A DailyMetric shaped exactly as `analyzeDay` leaves it when `matched` is empty: HRV/RHR
    /// present (so Charge can still be scored) but no sleep aggregates. This is the row a live-5.0
    /// day produces when gravity never offloaded.
    private func chargeableButUnsleptDaily(day: String) -> DailyMetric {
        DailyMetric(day: day,
                    totalSleepMin: nil,   // absent ⇒ no Rest composite
                    efficiency: nil,      // absent ⇒ no Rest composite
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                    restingHr: 52,        // present ⇒ recovery/Charge advances
                    avgHrv: 65,           // present ⇒ recovery/Charge advances
                    recovery: nil, strain: nil, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    func testUnsleptDailyProducesNilRestComposite() {
        let daily = chargeableButUnsleptDaily(day: "2026-07-02")
        // This is the exact guard at AnalyticsEngine.Rest.composite(daily:) line 696:
        //   guard let tstMin = d.totalSleepMin, tstMin > 0, let eff = d.efficiency else { return nil }
        XCTAssertNil(AnalyticsEngine.Rest.composite(daily: daily),
                     "No sleep aggregates ⇒ Rest.composite(daily:) is nil ⇒ no sleep_performance point written")
    }

    // MARK: - Stage 3: the display-side freeze this produces

    /// Reproduces the Today resolver's tail fallback (iOS LiquidTodayView.swift line 777 /
    /// Android TodayScreen.kt line 689): when today has no `sleep_performance` row, both
    /// platforms fall back to the latest value in the series. If new nights never write a row,
    /// that latest value is pinned to the last night that WAS scored — 93 — forever.
    // MARK: - The FIX CONTRACT (fails today, passes once #977 is fixed)

    /// The contract a fix must satisfy: a live-5.0 day that has HRV/RHR (Charge advances) but no
    /// staged sleep must NOT silently produce a nil Rest signal that freezes the display. Whatever
    /// the fix (an HR-only degraded Rest fallback for a chargeable-but-unslept day, OR forcing a
    /// gravity offload before scoring so `matched` is non-empty), the observable requirement is:
    /// a chargeable day yields SOME non-nil Rest signal so Today advances instead of tailing.
    ///
    /// This intentionally FAILS against today's code (Rest.composite(daily:) returns nil for such a
    /// day). Delete the XCTExpectFailure wrapper when the fix lands.
    func testChargeableDayShouldYieldAdvancingRestSignal_FIX() {
        XCTExpectFailure("#977 not yet fixed: a chargeable-but-unslept live-5.0 day yields a nil Rest signal") {
            let daily = chargeableButUnsleptDaily(day: "2026-07-02")
            XCTAssertNotNil(AnalyticsEngine.Rest.composite(daily: daily),
                            "A day that can score Charge must also surface SOME Rest signal, not freeze")
        }
    }

    func testTodayRestFreezesOnTailFallbackWhenNoNewPointWritten() {
        // sleep_performance series that stopped advancing days ago (last computed night = 93).
        let restByDay: [String: Double] = [
            "2026-06-25": 88,
            "2026-06-26": 91,
            "2026-06-27": 93,   // the last night gravity offloaded + scored
        ]
        let seriesTail = restByDay.max(by: { $0.key < $1.key })?.value   // == restSeries.last / maxByOrNull

        // Several later days ran (Charge advanced) but wrote NO sleep_performance row.
        for today in ["2026-06-28", "2026-06-29", "2026-06-30", "2026-07-01", "2026-07-02"] {
            let restToday = restByDay[today] ?? seriesTail   // offset 0 tail fallback
            XCTAssertEqual(restToday, 93,
                           "\(today): Today shows the frozen tail (93), never a fresh score")
        }
    }
}
