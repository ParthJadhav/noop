import Foundation
import StrandAnalytics

/// Assembles the Test Centre export bundle: gathers report.txt, meta.json, raw-capture and last-crash,
/// runs the redaction pass over EVERY file, applies the 20 MB cap, and hands the entries to
/// FileExport.exportBundle. This is the orchestrator behind the Report button.
///
/// The CRITICAL fix (spec section 5.3): today only the append(log:) sink scrubs (LiveState.swift:308),
/// so a serial embedded in raw-capture console text would ship unredacted. We re-run LiveState.redactPii
/// over every entry's text here, the single scrub point, and stamp meta.redaction = "v2" so a maintainer
/// can trust the scrub. Redaction stays the only scrub point; we just guarantee it covers the whole bundle.
enum TestBundleAssembler {

    /// The redaction stamp written into meta.json so a maintainer knows the whole-bundle scrub ran.
    static let redactionVersion = "v2"

    /// Re-run the redaction sink over every entry. Text entries are decoded as UTF-8, scrubbed via the same
    /// LiveState.redactPii used by the live sink, and re-encoded. A non-UTF-8 entry (none today) passes
    /// through untouched rather than risk corrupting binary. meta.json and report.txt have no PII shapes so
    /// they pass through byte-identical; raw-capture is where the embedded serials live.
    static func redactEntries(_ entries: [FileExport.BundleEntry]) -> [FileExport.BundleEntry] {
        entries.map { entry in
            guard let text = String(data: entry.data, encoding: .utf8) else { return entry }
            let scrubbed = LiveState.redactPii(text)
            return FileExport.BundleEntry(name: entry.name, data: Data(scrubbed.utf8))
        }
    }

    /// Hard cap the bundle at `capBytes` (20 MB default, under GitHub's 25 MB; spec section 5.4). The
    /// strap-log tail is already bounded, so only raw-capture can exceed. We keep the MOST-RECENT tail of
    /// raw-capture.jsonl (newest data is the most diagnostic) and trim from the front. Returns the capped
    /// entries plus whether any truncation happened, which the caller writes to meta.truncated.
    static func capEntries(_ entries: [FileExport.BundleEntry],
                           capBytes: Int = 20 * 1024 * 1024) -> (entries: [FileExport.BundleEntry], truncated: Bool) {
        let total = entries.reduce(0) { $0 + $1.data.count }
        guard total > capBytes else { return (entries, false) }
        // Budget for everything that is NOT raw-capture (kept whole), then give raw-capture the remainder.
        let rawName = "raw-capture.jsonl"
        let nonRaw = entries.filter { $0.name != rawName }.reduce(0) { $0 + $1.data.count }
        let budget = max(0, capBytes - nonRaw)
        var truncated = false
        let capped = entries.map { entry -> FileExport.BundleEntry in
            guard entry.name == rawName, entry.data.count > budget else { return entry }
            truncated = true
            // Keep the tail (most recent): the last `budget` bytes.
            let tail = entry.data.suffix(budget)
            return FileExport.BundleEntry(name: entry.name, data: Data(tail))
        }
        return (capped, truncated)
    }

    // MARK: - assemble (the entrypoint behind the Report button, the Group D integration seam)

    /// The build channel string for meta.json. Sideloaded iOS reads "sideload" with `signed=false`; an
    /// App Store / TestFlight iOS install reads "App Store"; macOS and Android are fixed per flavour. We
    /// never fabricate: the iOS read derives from IOSDiagnostics.isSideloaded.
    private static func buildProvenance() -> TestBundleMeta.Build {
        #if os(iOS)
        let sideloaded = IOSDiagnostics.capture().isSideloaded ?? true
        return TestBundleMeta.Build(channel: sideloaded ? "sideload" : "App Store", signed: !sideloaded)
        #elseif os(macOS)
        // The macOS build ships unsigned/un-notarized for anonymity (it's distributed via GitHub / brew).
        return TestBundleMeta.Build(channel: "GitHub", signed: false)
        #else
        return TestBundleMeta.Build(channel: "GitHub", signed: false)
        #endif
    }

    /// Gather the report files for `profile`, redact EVERY file, cap the bundle, then build and append
    /// meta.json (carrying the truncated flag from the cap) and redact-pass it too. Returns the final,
    /// already-redacted + already-capped entries ready for FileExport.exportBundle.
    ///
    /// Group B left this entrypoint to Group D (the Test Centre IA) on purpose: it is the one place that
    /// reaches into the live app (LiveState, TestCentre, the diagnostics) to gather the actual bytes, so
    /// it lives with the screen that binds the Report button. The pure primitives (redactEntries,
    /// capEntries) stay where Group B shipped them; this just composes them in the canonical order.
    /// `storage` / `strapModel` (#1002): the REAL probes, gathered async by TestCentreReport (the DB file
    /// size + per-table row counts come off the store actor, so the sync assembler can't read them
    /// itself). nil means the probe could not run (store unopenable) - meta then carries the zeroed
    /// block, which stays honest: zeros are "nothing readable", never a made-up figure.
    @MainActor
    static func assemble(profile: TestDomain, live: LiveState,
                         storage: TestBundleMeta.Storage? = nil,
                         strapModel: String? = nil) -> [FileExport.BundleEntry] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif

        // 0. The universal clock-drift line (RTC cluster #531/#767/#804/#812): rides EVERY export so a
        //    clock-broken strap self-diagnoses on a Sleep / Battery / any-mode report, not only in Connection
        //    mode. Built from the strap-range snapshot BLEManager banked (LiveState.strapRange). Appended to
        //    the report body BEFORE the completeness scan so its `dayOwner`-sibling token is part of the text
        //    the guard reads. No-op when no range was ever seen this session (no strap reply yet).
        let baseReport = live.exportableLogText()
        let universalLine = universalClockDriftLine(range: live.strapRange)
        let reportText = universalLine.map { baseReport + "\n[universal] " + $0 } ?? baseReport

        // 1. report.txt: the same exportable strap log the strap-log card shares, plus the universal
        //    clock-drift line. Already redacted by the append(log:) sink, but the whole-bundle redactEntries
        //    pass below re-scrubs it anyway (5.3).
        let reportEntry = FileExport.BundleEntry(name: "report.txt", data: Data(reportText.utf8))

        // 1b. Display & Performance: capture a screenshot for the .display profile (or any mode that
        //     declares includesScreenshot) as screenshot.png. The PNG is BINARY image bytes, not text, so it
        //     is kept OUT of the redactEntries pass on purpose: redaction scrubs text identifiers, never
        //     pixels (running raw PNG bytes through a UTF-8 decode/scrub would corrupt them). The screenshot
        //     is still covered by the mandatory review-before-share gate (nothing ships until the user taps
        //     Share), which the gate's note calls out. A capture only happens for the gated profile, so a
        //     non-display report never grabs a shot.
        let wantsShot = profile == .display
            || (TestModeRegistry.mode(profile)?.includesScreenshot ?? false)
        let shot: FileExport.BundleEntry? = wantsShot
            ? DisplayScreenshot.capturePNG().map { FileExport.BundleEntry(name: DisplayScreenshot.bundleName, data: $0) }
            : nil

        // 1c. raw-capture.jsonl: the on-device raw frame capture (when enabled in Settings -> Experimental),
        //     read from disk by URL. It is TEXT (JSON lines) where embedded console strings can carry a
        //     serial, so it IS run through the redactEntries pass below (the #1 reason the whole-bundle scrub
        //     exists, 5.3). Attached only when the file exists; a non-capturing install ships no raw entry.
        let rawCapture: FileExport.BundleEntry? = live.puffinCaptureURL
            .flatMap { fileEntry(at: $0, name: "raw-capture.jsonl") }

        // 1d. last-crash.txt: the most recent crash report, when one is present on disk. It is TEXT, so it
        //     ALSO rides the redactEntries pass. There is no crash producer wired yet, so this is normally
        //     absent; the lookup is a no-op then. Pluggable via `crashLogURL` so a future crash handler need
        //     only drop a file at the known path for it to start attaching, fully redacted, automatically.
        let crash: FileExport.BundleEntry? = crashLogURL()
            .flatMap { fileEntry(at: $0, name: "last-crash.txt") }

        // 2. Redact the TEXT files (report.txt, raw-capture.jsonl, last-crash.txt), then cap. The screenshot
        //    is included in the cap input (NOT the redact input) so its bytes COUNT against the 20 MB cap:
        //    capEntries budgets raw-capture as capBytes - (everything else), so a large/retina PNG shrinks
        //    the raw-capture tail rather than breaching the cap. Only raw-capture is trimmed; report.txt and
        //    last-crash are bounded and the PNG is kept whole.
        let textEntries = [reportEntry] + (rawCapture.map { [$0] } ?? []) + (crash.map { [$0] } ?? [])
        let redacted = redactEntries(textEntries)
        let (capped, truncated) = capEntries(redacted + (shot.map { [$0] } ?? []))
        var entries = capped

        // 2b. REPORT-COMPLETENESS GUARD (#812, generalised): for each domain ACTIVE during this capture,
        //     scan the redacted report.txt for its killer-trace token(s) and produce OK / INCOMPLETE. This
        //     makes a thin/empty report self-evident at submit time (the section is in the report the review
        //     gate shows) and names WHICH capture failed. Run over the REDACTED report so it sees exactly the
        //     bytes that ship. `.universal` is graded whenever any mode was active (the dayOwner +
        //     clock-drift lines ride every export). Re-read the redacted report.txt from `capped` so the scan
        //     and the shipped text can never diverge.
        let redactedReport = capped.first { $0.name == "report.txt" }
            .flatMap { String(data: $0.data, encoding: .utf8) } ?? reportText
        let active = activeDomains()
        let checks = CaptureCompleteness.evaluate(activeDomains: active, reportText: redactedReport)
        let section = CaptureCompleteness.reportSection(checks)
        if !section.isEmpty {
            // Append the Capture-check section to the shipped report.txt and re-redact (the section carries
            // no PII shapes, so the scrub is byte-identical, but it keeps the single-scrub-point invariant).
            let appended = redactedReport + "\n" + section
            entries = entries.map { e in
                e.name == "report.txt"
                    ? redactEntries([FileExport.BundleEntry(name: "report.txt", data: Data(appended.utf8))])[0]
                    : e
            }
        }

        // 3. meta.json: the machine-readable tie. The questionnaire answers are whatever the tester saved
        //    for this profile; profileStartedAt is ISO8601 from TestCentre. Storage + strapModel (#1002)
        //    are the caller's REAL probes (Phase 1 shipped hardcoded zeros here, so every meta.json read
        //    "db_bytes: 0" even on a multi-GB library and maintainers triaged blind); a nil probe falls
        //    back to the zeroed block - zeros mean "unreadable", we still never fabricate. The
        //    capture_check field carries the same OK/INCOMPLETE verdicts as the report section.
        let started = TestCentre.startedAt(profile).map { ISO8601DateFormatter().string(from: $0) }
        let meta = TestBundleMeta(
            schema: 1,
            appVersion: version,
            platform: platform,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            strapModel: strapModel,
            source: ["Live Bluetooth"],
            testProfile: profile.id,
            profileStartedAt: started,
            questionnaire: TestCentre.answers(profile),
            build: buildProvenance(),
            storage: storage ?? TestBundleMeta.Storage(dbBytes: 0, rows: [:], rawCaptureBytes: 0),
            redaction: redactionVersion,
            truncated: truncated,
            captureCheck: checks)

        // meta.json has no PII shapes, so the redact pass leaves it byte-identical, but we route it through
        // the same sink so the whole bundle is guaranteed to have passed one scrub point (5.3).
        entries += redactEntries([FileExport.BundleEntry(name: "meta.json", data: meta.encoded())])
        return entries
    }

    // MARK: - Helpers (universal clock-drift, bundle gather, active-domain view)

    /// Build the UNIVERSAL clock-drift line from the strap-range snapshot, or nil when no range was seen
    /// this session (no strap reply yet) OR only a firmware-only snapshot exists (newest==0, no real window).
    /// Pure; delegates the format to UniversalTrace so the line can never silently drift. `now` is injectable
    /// so the line is unit-testable without a live clock.
    static func universalClockDriftLine(range: LiveState.StrapRange?,
                                        now: Int = Int(Date().timeIntervalSince1970)) -> String? {
        guard let range, range.newestUnix > 0 else { return nil }
        return UniversalTrace.clockDriftLine(newestUnix: range.newestUnix, wallNowUnix: now,
                                             oldestUnix: range.oldestUnix, firmwareLayout: range.firmwareLayout)
    }

    /// The set of domains ACTIVE during this capture, plus `.universal` whenever any mode was on (the
    /// dayOwner + clock-drift lines ride every export). Reads the same zero-cost TestCentre.active gate the
    /// emitters check, so the guard grades exactly the modes that were capturing.
    static func activeDomains() -> Set<TestDomain> {
        var s = Set(TestDomain.allCases.filter { $0 != .universal && TestCentre.active($0) })
        if !s.isEmpty { s.insert(.universal) }
        return s
    }

    /// Read a file at `url` into a redactable bundle entry, or nil when the file is absent / unreadable, so a
    /// missing raw-capture / crash file is never a dead entry. The bytes are returned RAW; the caller runs
    /// them through redactEntries (these are text streams whose embedded console strings can carry a serial).
    static func fileEntry(at url: URL, name: String) -> FileExport.BundleEntry? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return FileExport.BundleEntry(name: name, data: data)
    }

    /// The on-disk path a crash report would live at, when a crash handler is wired. There is no producer
    /// yet, so this normally points at a non-existent file and `fileEntry` returns nil. Centralised here so a
    /// future handler need only write to this path for the crash log to start attaching (fully redacted)
    /// automatically. Lives in the app's caches dir so it is never iCloud-synced.
    static func crashLogURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("noop-last-crash.txt")
    }
}
