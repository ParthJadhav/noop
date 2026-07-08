import XCTest
@testable import Strand

/// Sleep & Recovery guidance / explainability layer — the Today lane pure mappers (spec 2026-06-20).
///
/// "No bare number without a STATE, a REASON, and a NEXT STEP." These pin the honest precedence and the
/// verbatim copy of the three Today components implemented in TodayView, so the wording and the honesty
/// rules can't silently regress and stay byte-for-byte in step with the Kotlin Today lane:
///   • Component 2 — explained score states (calibrating / carriedLastNight / needsStrap)
///   • Component 3 — recording status (recording / lastSynced Xm ago / notRecording)
///   • Component 4 — provenance label (On-device / Whoop / Apple Health = the real per-day merge winner)
final class TodayExplainabilityTests: XCTestCase {

    // MARK: - Component 2 — MetricTileState.resolve precedence

    func testScoreState_todayValueWins_isScored() {
        // A real today value beats everything else — the caller renders the number, not a state.
        let s = MetricTileState.resolve(hasTodayValue: true,
                                   calibratingNightsRemaining: 2,
                                   carriedDate: "14 Jun")
        XCTAssertEqual(s, .scored)
    }

    func testScoreState_noValueButCalibrating_isCalibratingWithRemaining() {
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: 3,
                                   carriedDate: "14 Jun")
        XCTAssertEqual(s, .calibrating(nightsRemaining: 3))
    }

    func testScoreState_noValueNoCalibrationButCarry_isCarriedLastNight() {
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: nil,
                                   carriedDate: "14 Jun")
        XCTAssertEqual(s, .carriedLastNight(date: "14 Jun", stale: false))
    }

    func testScoreState_carryWithinCap_isFreshLastNight() {
        // #779: a recent carry keeps the "Last night" framing.
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: nil,
                                   carriedDate: "14 Jun",
                                   carriedStale: false)
        XCTAssertEqual(s, .carriedLastNight(date: "14 Jun", stale: false))
        XCTAssertEqual(s.title, "Last night · 14 Jun")
    }

    func testScoreState_staleCarry_relabelsLatestSleep() {
        // #779: a weeks-old carry is still shown (not a bare blank) but relabelled so the number is never
        // passed off as "Last night".
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: nil,
                                   carriedDate: "14 May",
                                   carriedStale: true)
        XCTAssertEqual(s, .carriedLastNight(date: "14 May", stale: true))
        XCTAssertEqual(s.title, "Latest sleep · 14 May")
        XCTAssertEqual(s.accessibilityText,
                       "Latest sleep, 14 May. This is your last scored session. Wear the strap overnight for a fresh score.")
    }

    func testScoreState_nothingBanked_isNeedsStrap() {
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: nil,
                                   carriedDate: nil)
        XCTAssertEqual(s, .needsStrap)
    }

    func testScoreState_calibratingRemainingClampsToAtLeastOne() {
        // Canonical contract: while calibrating, never render "0 more nights" — clamp to >= 1.
        let zero = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: 0,
                                   carriedDate: nil)
        XCTAssertEqual(zero, .calibrating(nightsRemaining: 1))

        let negative = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: -3,
                                   carriedDate: nil)
        XCTAssertEqual(negative, .calibrating(nightsRemaining: 1))
    }

    func testScoreState_calibratingClampedValueDrivesSingularNightCopy() {
        // The clamped-to-1 boundary must read the SINGULAR "1 more night", proving the plural rule
        // reads the clamped payload, not the raw caller value.
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: 0,
                                   carriedDate: nil)
        XCTAssertEqual(s.accessibilityText,
                       "Calibrating. Building your baseline. About 1 more night until your scores are personal.")
    }

    // MARK: - Component 2 — verbatim copy (via the VoiceOver text, which surfaces the visible words)

    func testScoreState_calibratingDetail_pluralisesNights() {
        XCTAssertEqual(MetricTileState.calibrating(nightsRemaining: 3).accessibilityText,
                       "Calibrating. Building your baseline. About 3 more nights until your scores are personal.")
    }

    func testScoreState_calibratingDetail_singularNight() {
        XCTAssertEqual(MetricTileState.calibrating(nightsRemaining: 1).accessibilityText,
                       "Calibrating. Building your baseline. About 1 more night until your scores are personal.")
    }

    func testScoreState_carriedLastNight_stampsDate() {
        XCTAssertEqual(MetricTileState.carriedLastNight(date: "14 Jun", stale: false).accessibilityText,
                       "Last night, 14 Jun. Tonight's lands after you sleep with the strap on.")
    }

    func testScoreState_needsStrap_copy() {
        XCTAssertEqual(MetricTileState.needsStrap.accessibilityText,
                       "Needs the strap. No data for today. Was your strap worn and connected overnight?")
    }

    func testScoreState_scored_hasNoStateText() {
        XCTAssertNil(MetricTileState.scored.title)
        XCTAssertNil(MetricTileState.scored.detail)
        XCTAssertNil(MetricTileState.scored.accessibilityText)
    }

    func testScoreState_honesty_calibratingAndNeedsStrapShowNoNumber() {
        // The honesty rule: calibrating / needsStrap never carry a fabricated value. Their texts must
        // not contain a percent sign or a digit that could be read as a score (the night-count is fine).
        XCTAssertFalse(MetricTileState.needsStrap.accessibilityText!.contains("%"))
        XCTAssertFalse(MetricTileState.calibrating(nightsRemaining: 2).accessibilityText!.contains("%"))
    }

    func testScoreState_copy_hasNoEmDash() {
        let states: [MetricTileState] = [.calibrating(nightsRemaining: 2),
                                    .carriedLastNight(date: "14 Jun", stale: false),
                                    .carriedLastNight(date: "14 May", stale: true),
                                    .needsStrap]
        for s in states {
            XCTAssertFalse(s.accessibilityText!.contains("\u{2014}"),
                           "MetricTileState \(s) must not contain an em-dash")
        }
    }

    // MARK: - Component 3 — RecordingState.resolve

    func testRecordingState_connectedWithLiveHR_isRecording() {
        // The canonical gate: `recording` IFF connected AND a live heart-rate sample is present.
        let s = RecordingState.resolve(connected: true, heartRate: 62, lastSyncedAt: 1000, now: 2000)
        XCTAssertEqual(s, .recording)
    }

    func testRecordingState_connectedButNoLiveHR_isNotRecording() {
        // Connected but no live HR yet (handshaking / off-wrist / no PPG) is honestly NOT recording.
        // With a known last-sync it falls back to "Last synced Xm ago" rather than a false "Recording".
        let now: TimeInterval = 10_000
        let s = RecordingState.resolve(connected: true, heartRate: nil, lastSyncedAt: now - 120, now: now)
        XCTAssertEqual(s, .lastSynced(minutesAgo: 2))
    }

    func testRecordingState_connectedNoLiveHR_noSync_isNotRecording() {
        // Connected, no live HR, and nothing ever synced → "Not recording" (never a false "Recording").
        let s = RecordingState.resolve(connected: true, heartRate: nil, lastSyncedAt: nil, now: 10_000)
        XCTAssertEqual(s, .notRecording)
    }

    func testRecordingState_notConnectedWithStaleHR_isNotRecording() {
        // A stale HR sample without a live connection can never be "Recording".
        let s = RecordingState.resolve(connected: false, heartRate: 62, lastSyncedAt: nil, now: 10_000)
        XCTAssertEqual(s, .notRecording)
    }

    func testRecordingState_notConnectedButRecentlySynced_isLastSynced() {
        // 5 minutes (300s) ago → "Last synced 5m ago".
        let now: TimeInterval = 10_000
        let s = RecordingState.resolve(connected: false, heartRate: nil, lastSyncedAt: now - 300, now: now)
        XCTAssertEqual(s, .lastSynced(minutesAgo: 5))
    }

    func testRecordingState_subMinuteSync_roundsUpToOneMinute() {
        // 30s ago should read "1m ago", never "0m ago" (ceil).
        let now: TimeInterval = 10_000
        let s = RecordingState.resolve(connected: false, heartRate: nil, lastSyncedAt: now - 30, now: now)
        XCTAssertEqual(s, .lastSynced(minutesAgo: 1))
    }

    func testRecordingState_exactMinuteSync_isNotRoundedUp() {
        // Exactly 120s ago is exactly 2m — ceil must not bump an exact boundary to 3m.
        let now: TimeInterval = 10_000
        let s = RecordingState.resolve(connected: false, heartRate: nil, lastSyncedAt: now - 120, now: now)
        XCTAssertEqual(s, .lastSynced(minutesAgo: 2))
    }

    func testRecordingState_clockSkewFutureSync_clampsToZeroMinutes() {
        // A strap-clock-skew future timestamp must never read negative.
        let now: TimeInterval = 10_000
        let s = RecordingState.resolve(connected: false, heartRate: nil, lastSyncedAt: now + 600, now: now)
        XCTAssertEqual(s, .lastSynced(minutesAgo: 0))
    }

    func testRecordingState_neverSynced_isNotRecording() {
        let s = RecordingState.resolve(connected: false, heartRate: nil, lastSyncedAt: nil, now: 10_000)
        XCTAssertEqual(s, .notRecording)
    }

    // MARK: - Component 3 — verbatim copy

    func testRecordingState_recording_copy() {
        XCTAssertEqual(RecordingState.recording.accessibilityText,
                       "Recording. Your strap is connected and saving data.")
    }

    func testRecordingState_lastSynced_copy() {
        XCTAssertEqual(RecordingState.lastSynced(minutesAgo: 7).accessibilityText,
                       "Last synced 7 minutes ago. Reconnect to pull the latest.")
    }

    func testRecordingState_notRecording_copy() {
        XCTAssertEqual(RecordingState.notRecording.accessibilityText,
                       "Not recording. Strap not connected. Tap to connect.")
    }

    func testRecordingState_copy_hasNoEmDash() {
        let states: [RecordingState] = [.recording, .lastSynced(minutesAgo: 5), .notRecording]
        for s in states {
            XCTAssertFalse(s.accessibilityText.contains("\u{2014}"),
                           "RecordingState \(s) must not contain an em-dash")
        }
    }

    // MARK: - Component 4 — provenance label (the real per-day merge winner)

    func testProvenance_computedStrapSibling_isOnDevice() {
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "my-whoop-noop", deviceId: "my-whoop"),
                       "On-device")
    }

    func testProvenance_importedStrapSource_isWhoop() {
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "my-whoop", deviceId: "my-whoop"),
                       "Whoop")
    }

    func testProvenance_appleHealthSource_isAppleHealth() {
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "apple-health", deviceId: "my-whoop"),
                       "Apple Health")
    }

    func testProvenance_nonDefaultDeviceId_stillMapsComputedAndImported() {
        // A strap with a non-"my-whoop" device id still resolves its own sibling + imported source.
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "whoop5-AB12-noop", deviceId: "whoop5-AB12"),
                       "On-device")
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "whoop5-AB12", deviceId: "whoop5-AB12"),
                       "Whoop")
    }

    func testProvenance_otherKnownSource_keepsItsDisplayName() {
        // Mi Band is a real merge winner — keep its own name, never a blanket on-device claim.
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "xiaomi-band", deviceId: "my-whoop"),
                       "Mi Band")
    }

    // MARK: - Apple Watch provenance (M1) — Today-only "Apple Watch" relabel of the apple-health source

    func testIsWatchSource_appleHealthSource_isTrue() {
        XCTAssertTrue(TodayView.isWatchSource("apple-health", appleHealthSource: "apple-health"))
    }

    func testIsWatchSource_strapOrNil_isFalse() {
        // A strap-sourced score (or no resolved source at all) is never the watch.
        XCTAssertFalse(TodayView.isWatchSource("my-whoop", appleHealthSource: "apple-health"))
        XCTAssertFalse(TodayView.isWatchSource(nil, appleHealthSource: "apple-health"))
    }

    func testTodayChipLabel_appleHealthSource_readsAppleWatch() {
        // The audience knows the device, not the framework — a watch-sourced score reads "Apple Watch".
        XCTAssertEqual(
            TodayView.todayProvenanceChipLabel(rawSource: "apple-health", deviceId: "my-whoop",
                                               appleHealthSource: "apple-health"),
            "Apple Watch")
    }

    func testTodayChipLabel_nonWatchSources_deferToSharedLabel() {
        // Everything else stays byte-identical to the shared provenance label (and the footer): the
        // Today relabel only touches the apple-health source.
        XCTAssertEqual(
            TodayView.todayProvenanceChipLabel(rawSource: "my-whoop", deviceId: "my-whoop",
                                               appleHealthSource: "apple-health"),
            "Whoop")
        XCTAssertEqual(
            TodayView.todayProvenanceChipLabel(rawSource: "my-whoop-noop", deviceId: "my-whoop",
                                               appleHealthSource: "apple-health"),
            "On-device")
        XCTAssertEqual(
            TodayView.todayProvenanceChipLabel(rawSource: "xiaomi-band", deviceId: "my-whoop",
                                               appleHealthSource: "apple-health"),
            "Mi Band")
    }
}
