import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandImport

/// Settings -> Test Centre. The single home for every diagnostic, log and test control (spec section 7).
///
/// Four sections: domain test modes (rendered from the registry projection), diagnostic tools, export
/// and auto-export, advanced/experimental. Section 1 iterates TestCentreLayout.visibleModes so adding a
/// profile later is a registry entry, never a new screen. The lower three sections re-host the same
/// bindings and actions that live in SettingsView (strap log, recalibrate, scheduled export, the 5/MG
/// experimental toggles) so the Test Centre is the one place to find them; SettingsView keeps a thin nav
/// link in. No em-dash in any string here.
struct TestCentreView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState

    /// The Report orchestrator: assembles the redacted bundle, runs the mandatory review gate, shares.
    @StateObject private var report = TestCentreReport()

    /// Re-read activation on appear so a toggle flip elsewhere reflects here.
    @State private var refreshToken = 0

    // Section 2: recalibrate confirm.
    @State private var showRecalibrateConfirm = false
    @State private var infoTitle = ""
    @State private var infoMessage = ""
    @State private var showInfo = false

    // Section 3: scheduled daily auto-export, the same ScheduledDebugExport store the Settings card uses.
    @State private var debugExportOn = ScheduledDebugExport.isEnabled
    @State private var debugExportMinutes = ScheduledDebugExport.timeMinutes

    // Section 4: the experimental toggles, on the SAME @AppStorage keys as SettingsView (preserved per
    // spec section 10), so toggling here and there is one and the same setting.
    @AppStorage(PuffinExperiment.experimentalSleepV2Key) private var experimentalSleepV2Enabled = false
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrvEnabled = false
    @AppStorage(PuffinExperiment.defaultsKey) private var puffinExperiments = false
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false
    @AppStorage(PuffinExperiment.broadcastHrKey) private var broadcastHrEnabled = false
    @AppStorage(PuffinFrameRecorder.enabledKey) private var puffinCapture = false

    /// The strap model the user last picked, the same key SettingsView's showFiveMGControls gate reads.
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue

    /// True when the connected strap is a 5/MG, so the 5/MG experimental block shows. Mirrors the
    /// SettingsView gate (#22): a confident 4.0 owner never sees controls that cannot touch their strap.
    private var is5MG: Bool { selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue }

    /// The "whole app" report profile for the section-3 manual Report button. master is not a registry
    /// mode (it has no wear-and-capture flow), so the deep-link self-applies the test:all label via this.
    static let masterReportMode = TestMode(
        domain: .master, title: String(localized: "Bug report"), blurb: "", icon: "ladybug", priority: .high,
        captures: [], questionnaire: [], liveReadout: [],
        capture: .toggle, includesScreenshot: false, requires5MG: false)

    var body: some View {
        ScreenScaffold(title: "Test Centre",
                       subtitle: "Turn on a test for the thing that's wrong, wear the strap, then tap Report. All on \(Platform.deviceNounPhrase).") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                domainModesCard.staggeredAppear(index: 0)
                diagnosticToolsCard.staggeredAppear(index: 1)
                exportCard.staggeredAppear(index: 2)
                advancedCard.staggeredAppear(index: 3)
            }
        }
        .id(refreshToken)
        .onAppear {
            refreshToken &+= 1
            ScheduledDebugExport.activateIfEnabled()
        }
        .sheet(item: $report.pending) { _ in
            ReportReviewSheet(report: report)
        }
        .confirmationDialog("Recalibrate your Charge baseline?",
                            isPresented: $showRecalibrateConfirm, titleVisibility: .visible) {
            Button("Recalibrate") { recalibrateCharge() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This restarts the roughly 4-night build-up for Charge and your HRV baseline. Your history stays.")
        }
        .alert(infoTitle, isPresented: $showInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(infoMessage)
        }
    }

    // MARK: - Section 1: Domain test modes (rendered from the registry projection)

    @ViewBuilder private var domainModesCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("TEST MODES")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Each test logs extra detail for one part of the app while you wear the strap, then bundles it for a bug report.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                let modes = TestCentreLayout.visibleModes(is5MG: is5MG)
                ForEach(Array(modes.enumerated()), id: \.element.id) { idx, mode in
                    if idx > 0 { Divider().overlay(StrandPalette.hairline) }
                    TestModeRow(mode: mode, report: report)
                }
            }
        }
    }

    // MARK: - Section 2: Diagnostic tools (strap log + recalibrate + env dump)

    @ViewBuilder private var diagnosticToolsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("DIAGNOSTIC TOOLS")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)

                // Strap log, the same exportableLogText the Settings + Live strap-log cards share.
                HStack(spacing: 12) {
                    Text("STRAP LOG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Button("Copy") { PlatformPasteboard.copy(live.exportableLogText()) }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                    Button("Save…") {
                        FileExport.exportText(live.exportableLogText(),
                                              suggestedName: FileExport.timestampedName("noop-strap-log", ext: "txt"))
                    }
                    .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                }
                Text("Grab this when you report a bug. It tells me what the app saw.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                // Recalibrate Charge baseline: the same Baselines.recalibrateRecoveryBaselines call the
                // Settings Recovery card uses.
                NoopButton("Recalibrate Charge baseline", systemImage: "arrow.triangle.2.circlepath", kind: .secondary) {
                    showRecalibrateConfirm = true
                }
                Text("Re-anchors every baseline that feeds Charge to your recent nights. No stored day is deleted.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                // Environment dump: the IOSDiagnostics-backed block exportableLogText already carries,
                // surfaced as a copyable readout (spec section 3.4).
                NoopButton("Copy environment dump", systemImage: "info.circle", kind: .secondary) {
                    PlatformPasteboard.copy(live.exportableLogText())
                }
            }
        }
    }

    // MARK: - Section 3: Export and auto-export (manual Report + scheduled export)

    @ViewBuilder private var exportCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("EXPORT")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)

                NoopButton("Report a bug with my log", systemImage: "paperplane", kind: .primary) {
                    // A generic "whole app" report: the master profile so the deep-link self-applies the
                    // test:all label. master is not in the registry (it is not a wear-and-capture mode), so
                    // build the lightweight mode inline.
                    report.start(mode: TestCentreView.masterReportMode, live: live, repo: model.repo)
                }
                Text("Builds a redacted .zip, shows you exactly what it contains, then opens a prefilled GitHub issue. You attach the file on the next screen.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let status = report.lastStatus {
                    Text(status)
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // M3 (#812): the mobile copy fallback, now visible. If the user cannot attach the .zip in
                // the GitHub composer, this pastes the redacted report into the clipboard to drop straight
                // into the issue. Only appears after a confirmed share on the path that offers it.
                if let reportText = report.copyableReport {
                    Button {
                        PlatformPasteboard.copy(reportText)
                    } label: {
                        Label("Copy report.txt", systemImage: "doc.on.clipboard")
                            .font(StrandFont.subhead)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Copy the redacted report to the clipboard")
                }

                Divider().overlay(StrandPalette.hairline)

                // Scheduled daily auto-export, the same ScheduledDebugExport reads/writes as the Settings
                // Diagnostics card. iOS BGAppRefresh is best-effort, the honest caption is kept.
                Toggle(isOn: $debugExportOn) {
                    Text("Daily auto-export of the strap log")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
                .onChangeCompat(of: debugExportOn) { on in ScheduledDebugExport.setEnabled(on) }

                if debugExportOn {
                    HStack {
                        Text("Time of day").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        DatePicker("", selection: debugExportTimeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Daily auto-export time")
                    }
                    NoopButton("Run now", systemImage: "square.and.arrow.down.on.square", kind: .secondary) {
                        runScheduledExportNow()
                    }
                    Text("On iPhone this is best-effort (iOS decides when background tasks run). Everything stays on \(Platform.deviceNounPhrase).")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Section 4: Advanced / experimental

    @ViewBuilder private var advancedCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("ADVANCED")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)

                // Model-agnostic advanced toggles (shown on every strap), same @AppStorage keys as Settings.
                Toggle(isOn: $experimentalSleepV2Enabled) {
                    Text("Experimental sleep staging (V2)")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)

                Toggle(isOn: $continuousHrvEnabled) {
                    Text("Continuous HRV capture")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
                .onChangeCompat(of: continuousHrvEnabled) { on in model.ble.setKeepRealtimeForData(on) }

                // 5/MG-only probes, hidden off a 4.0 strap (the #22 gate, same as SettingsView).
                if is5MG {
                    Divider().overlay(StrandPalette.hairline)
                    Text("WHOOP 5 / MG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)

                    Toggle(isOn: $puffinExperiments) {
                        Text("Try WHOOP 5/MG protocol probes")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch).tint(StrandPalette.accent)

                    Toggle(isOn: $deepDataEnabled) {
                        Text("Unlock WHOOP 5/MG deep data (R22)")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch).tint(StrandPalette.accent)

                    Toggle(isOn: $broadcastHrEnabled) {
                        Text("Broadcast heart rate (Garmin/ANT)")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch).tint(StrandPalette.accent)
                    .onChangeCompat(of: broadcastHrEnabled) { on in model.ble.setBroadcastHr(on) }

                    Toggle(isOn: $puffinCapture) {
                        Text("Record puffin frames to a file")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch).tint(StrandPalette.accent)
                }

                Text("These are experimental probes, off by default. The fuller WHOOP 5/MG controls and the raw-sensor CSV export still live in Settings under Diagnostics.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Shared actions (same calls as the SettingsView controls these re-host)

    /// Re-anchor every baseline that feeds Charge from now, via the single cross-platform source of
    /// truth, then kick a recompute. Same path as the Settings Recovery card.
    private func recalibrateCharge() {
        Baselines.recalibrateRecoveryBaselines()
        Task {
            await model.intelligence.analyzeRecent()
            await model.repo.refresh()
        }
        infoTitle = String(localized: "Charge baseline recalibrating")
        infoMessage = String(localized: "NOOP will re-learn your baseline from tonight's data onward. Your history is kept, and it takes a few nights to settle.")
        showInfo = true
    }

    private var debugExportTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = debugExportMinutes / 60
                c.minute = debugExportMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                debugExportMinutes = m
                ScheduledDebugExport.setTimeMinutes(m)
            }
        )
    }

    private func runScheduledExportNow() {
        model.ble.flushPuffinCaptures()
        let url = ScheduledDebugExport.runNow(captureURL: live.puffinCaptureURL)
        if let url {
            infoTitle = String(localized: "Strap log exported")
            #if os(iOS)
            infoMessage = String(localized: "Saved \(url.lastPathComponent) to NOOP's folder in the Files app.")
            #else
            infoMessage = String(localized: "Saved \(url.lastPathComponent) to your Documents folder.")
            #endif
        } else {
            infoTitle = String(localized: "Export failed")
            infoMessage = String(localized: "Couldn't write the strap log right now.")
        }
        showInfo = true
    }
}

/// One domain-test-mode row: icon + title + status + blurb, a toggle wired to TestCentre, and a Report
/// action. Toggling calls TestCentre.activate/deactivate (the single prefs namespace).
private struct TestModeRow: View {
    let mode: TestMode
    @ObservedObject var report: TestCentreReport
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel
    @State private var on: Bool = false

    private var elapsed: Double? {
        TestCentre.startedAt(mode.domain).map { Date().timeIntervalSince($0) }
    }

    /// The HONEST per-mode captured-day count for a guided row (#965): distinct days THIS mode produced its
    /// own trace on, read from the same shareable log the report exports, so each active mode accumulates
    /// its OWN count instead of every guided row sharing one elapsed-clock number. nil for a toggle mode
    /// (no "K of N") and when the mode is off. Recomputes with `live.log` (published) so the row updates as
    /// new capture days land.
    private var capturedUnits: Int? {
        guard on, case .guided = mode.capture else { return nil }
        return CaptureAccumulator.capturedDays(domain: mode.domain,
                                               reportText: live.exportableLogText(),
                                               tzOffsetSeconds: TimeZone.current.secondsFromGMT())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: mode.icon)
                    .foregroundStyle(StrandPalette.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    Text(TestCentreLayout.statusText(for: mode, active: on, elapsedSeconds: elapsed,
                                                     capturedUnits: capturedUnits))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $on)
                    .labelsHidden()
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("\(mode.title) test mode")
                    .onChangeCompat(of: on) { isOn in
                        if isOn { TestCentre.activate(mode.domain) } else { TestCentre.deactivate(mode.domain) }
                        // Display & Performance owns a live frame monitor. It must run ONLY while the mode
                        // is on: start it on toggle-on (after wiring its sink to the redacting .display
                        // log), tear it down on toggle-off so no display link survives. Zero-cost when off.
                        if mode.domain == .display {
                            if isOn { startDisplayMonitor() } else { DisplayPerformanceMonitor.shared.stop() }
                        }
                    }
            }
            Text(mode.blurb)
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            // Live readout (Group E/F): the per-mode panel binding the registry's liveReadout ids. Shown
            // only while the mode is on, so an inactive row stays compact.
            if on, mode.domain == .sleep {
                SleepReadoutPanel(live: live)
            }
            if on, mode.domain == .battery {
                BatteryReadoutPanel(live: live)
            }
            if on, mode.domain == .connection {
                ConnectionReadoutPanel(live: live)
            }
            if on, mode.domain == .recovery {
                RecoveryReadoutPanel(live: live)
            }
            if on, mode.domain == .hrv {
                HrvReadoutPanel(live: live)
            }
            if on, mode.domain == .steps {
                StepsReadoutPanel(live: live)
            }
            if on, mode.domain == .workouts {
                WorkoutsReadoutPanel(live: live)
            }
            if on, mode.domain == .dataImport {
                ImportReadoutPanel(live: live)
            }
            if on, mode.domain == .display {
                DisplayReadoutPanel(live: live)
            }
            HStack {
                Spacer()
                Button("Report") { report.start(mode: mode, live: live, repo: model.repo) }
                    .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                    .accessibilityLabel("Report a \(mode.title) bug")
            }
        }
        .onAppear {
            on = TestCentre.active(mode.domain)
            // If the Display mode was already on when the screen appears, (re)start its frame monitor and
            // wire the sink, so a monitor that was torn down (e.g. the screen left and came back) resumes.
            if mode.domain == .display, on { startDisplayMonitor() }
        }
        .onDisappear {
            // Leaving the screen tears the frame monitor down so no display link survives a navigation
            // away. The mode flag stays on (the user's test is still active); the monitor resumes on
            // .onAppear above. This keeps the perpetual-display-link contract: a link exists only while the
            // Test Centre is on screen with the mode on.
            if mode.domain == .display { DisplayPerformanceMonitor.shared.stop() }
        }
    }

    /// Wire the Display monitor's sink to the redacting `.display` log and start it. The sink is set every
    /// start so a fresh LiveState (e.g. after a screen re-entry) is always the live target.
    private func startDisplayMonitor() {
        DisplayPerformanceMonitor.shared.emit = { [weak live] line in
            live?.append(log: line, domain: .display)
        }
        // CAPTURE-D (#797): wire the data-volume provider so start() emits one `dataVolume` line read STRAIGHT
        // from the store (Repository.dataVolumeSnapshot queries the store, not the @Published caches), so an
        // import-driven-lag report shows the read-set behind the frame stats.
        DisplayPerformanceMonitor.shared.dataVolumeProvider = { [weak model] in
            await model?.repo.dataVolumeSnapshot()
        }
        DisplayPerformanceMonitor.shared.start()
    }
}

/// The Sleep & Rest live-readout panel (Group E): HR density, gravity coverage, and the gate that
/// fired tonight, bound from the pure `SleepReadout` source over LiveState's live buffers + tagged log
/// tail. No hardcoded colours; uses the same tokens as the surrounding Test Centre rows.
private struct SleepReadoutPanel: View {
    @ObservedObject var live: LiveState

    var body: some View {
        let hrDensity = SleepReadout.hrDensityPerMinute(hr: live.recentHrSamples)
        let gravCoverage = SleepReadout.gravityCoverageFraction(gravity: live.recentGravitySamples, hr: live.recentHrSamples)
        let lastGate = SleepReadout.lastGateFired(taggedTail: live.taggedTail(domain: .sleep))
        VStack(alignment: .leading, spacing: 4) {
            ReadoutRow(label: String(localized: "HR density (per min)"),
                       value: live.recentHrSamples.isEmpty ? String(localized: "no live HR yet") : String(format: "%.1f", hrDensity))
            ReadoutRow(label: String(localized: "Gravity coverage"),
                       value: live.recentGravitySamples.isEmpty ? String(localized: "no live gravity yet") : String(format: "%.0f%%", gravCoverage * 100))
            ReadoutRow(label: String(localized: "Last gate fired"), value: lastGate ?? String(localized: "no night yet"))
        }
        .padding(.top, 2)
    }
}

/// The Battery & Charging live-readout panel (Group F): current SoC, the "~X days left" estimate, and
/// whether the discharge slope is the user's own measured rate or the rated fallback. Bound from
/// LiveState.batteryReadout over the SAME banked SoC series the Today badge reads, so the panel never
/// diverges from the headline number. No hardcoded colours; uses the same ReadoutRow tokens as the Sleep
/// panel above. No em-dash in any string here.
private struct BatteryReadoutPanel: View {
    @ObservedObject var live: LiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ReadoutRow(label: String(localized: "Current charge"), value: live.batteryReadout("currentSoc"))
            ReadoutRow(label: String(localized: "Estimated runtime left"), value: live.batteryReadout("estimateDaysLeft"))
            ReadoutRow(label: String(localized: "Slope source"), value: live.batteryReadout("slopeSource"))
        }
        .padding(.top, 2)
    }
}

/// The Connection & Sync live-readout panel: connection uptime, the involuntary-reconnect count this run,
/// and the last offload result, all parsed from the `.connection`-tagged log tail (plus the live connection
/// state for the up/down headline) by the pure `ConnectionReadout`. Binding off the tagged tail mirrors the
/// Recovery / HRV panels, so the BLE layer needs no new published properties. No hardcoded colours; uses the
/// same ReadoutRow tokens as the other panels. No em-dash in any string here.
private struct ConnectionReadoutPanel: View {
    @ObservedObject var live: LiveState

    var body: some View {
        let tail = live.taggedTail(domain: .connection)
        let now = Int(Date().timeIntervalSince1970)
        // Trust the live link state for the up/down headline; fall back to the tagged tail for the
        // since-when. Once disconnected, the link state is the source of truth (the tail may still hold a
        // stale uptimeStart from the last connect).
        let uptime = live.connected
            ? ConnectionReadout.uptimeLabel(taggedTail: tail, nowUnix: now)
            : String(localized: "not connected")
        let reconnects = ConnectionReadout.reconnectCount(taggedTail: tail)
        let lastOffload = ConnectionReadout.lastOffloadResult(taggedTail: tail)
        // #990: rows drained this session (the running/final offload tally) BESIDE the persisted all-time
        // counter, so a strap stuck in a pull-restart loop still shows the install-lifetime progress the
        // per-session number keeps resetting away.
        let sessionRows = ConnectionReadout.sessionRows(taggedTail: tail)
        let allTimeRows = TestCentre.cumulativeDrainedRows()
        // #987: clock latch + frame liveness. The correlated device clock is parsed from the same log the
        // export ships (pure ConnectionReadout parsers), the last-frame stamp off the non-published
        // LiveState field FrameRouter writes.
        let deviceClock = ConnectionReadout.clockCorrelatedDevice(logLines: live.log)
        let rtcWarning = ConnectionReadout.rtcWarning(deviceClockUnix: deviceClock,
                                                      strapNewestUnix: live.strapRange?.newestUnix)
        VStack(alignment: .leading, spacing: 4) {
            ReadoutRow(label: String(localized: "Connection uptime"), value: uptime)
            ReadoutRow(label: String(localized: "Reconnects this run"), value: String(reconnects))
            ReadoutRow(label: String(localized: "Last offload result"), value: lastOffload ?? String(localized: "no offload yet"))
            ReadoutRow(label: String(localized: "Rows drained (session)"),
                       value: sessionRows.map(String.init) ?? String(localized: "no offload yet"))
            ReadoutRow(label: String(localized: "Rows drained (all time)"), value: String(allTimeRows))
            ReadoutRow(label: String(localized: "Clock latched"),
                       value: ConnectionReadout.clockLatchedLabel(deviceClockUnix: deviceClock))
            ReadoutRow(label: String(localized: "Last frame"),
                       value: ConnectionReadout.lastFrameLabel(lastFrameUnix: live.lastFrameAtUnix, nowUnix: now))
            if let rtcWarning {
                // #987: the plain-words 1970/71 warning - amber, not a bare token, because this is the
                // single most common "no history" root cause and the fix is in the sentence.
                Text(rtcWarning)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(rtcWarning)
            }
        }
        .padding(.top, 2)
    }
}

/// The Recovery (Charge) live-readout panel (Group G): the last Charge term-breakdown from the
/// `.recovery`-tagged log tail (the score + band, or the nil reason when a night could not be scored).
/// Bound from the pure `TestReadout.lastChargeBreakdown`, parsed from the SAME tagged lines the Recovery
/// emitter writes, so the panel never diverges from the headline Charge number. No hardcoded colours;
/// uses the same ReadoutRow tokens as the Sleep / Battery panels. No em-dash in any string here.
private struct RecoveryReadoutPanel: View {
    @ObservedObject var live: LiveState

    var body: some View {
        let last = TestReadout.lastChargeBreakdown(taggedTail: live.taggedTail(domain: .recovery))
        VStack(alignment: .leading, spacing: 4) {
            ReadoutRow(label: String(localized: "Last Charge breakdown"), value: last ?? String(localized: "no night scored yet"))
        }
        .padding(.top, 2)
    }
}

/// The HRV & Autonomic live-readout panel (Group G): the last HRV computation from the `.hrv`-tagged log
/// tail (RMSSD / SDNN, or "no reading" when the cleaning gates filtered the capture out). Bound from the
/// pure `TestReadout.lastHrvComputation`, parsed from the SAME tagged lines the HRV emitter writes, so the
/// panel reads the same outcome the snapshot screen showed. No hardcoded colours. No em-dash here.
private struct HrvReadoutPanel: View {
    @ObservedObject var live: LiveState

    var body: some View {
        let last = TestReadout.lastHrvComputation(taggedTail: live.taggedTail(domain: .hrv))
        VStack(alignment: .leading, spacing: 4) {
            ReadoutRow(label: String(localized: "Last HRV reading"), value: last ?? String(localized: "no reading yet"))
        }
        .padding(.top, 2)
    }
}

/// The Steps live-readout panel: today's steps and the calibration state, parsed from the `.steps`-tagged
/// log tail the Steps test-mode emitters write (the WHOOP-4 calibration / estimate lines and the 5/MG raw
/// scaledSteps), by the pure `StepsReadout`. Binding off the tagged tail mirrors the Recovery / HRV panels,
/// so the analytics layer needs no new published properties. No hardcoded colours; uses the same ReadoutRow
/// tokens as the other panels. No em-dash in any string here.
private struct StepsReadoutPanel: View {
    @ObservedObject var live: LiveState

    var body: some View {
        let tail = live.taggedTail(domain: .steps)
        let steps = StepsReadout.stepsToday(taggedTail: tail)
        let calState = StepsReadout.calibrationState(taggedTail: tail)
        VStack(alignment: .leading, spacing: 4) {
            ReadoutRow(label: String(localized: "Steps today"), value: steps.map(String.init) ?? String(localized: "no estimate yet"))
            ReadoutRow(label: String(localized: "Calibration"), value: calState ?? String(localized: "no calibration yet"))
        }
        .padding(.top, 2)
    }
}

/// The Workouts & GPS live-readout panel: the last session summary (event + sport + counts), parsed from the
/// `.workouts`-tagged log tail the session-lifecycle emitter writes, by the pure `WorkoutsReadout`. Binding
/// off the tagged tail mirrors the Recovery / HRV / Steps panels, so the app layer needs no new published
/// properties. No hardcoded colours; uses the same ReadoutRow tokens as the other panels. No em-dash here.
private struct WorkoutsReadoutPanel: View {
    @ObservedObject var live: LiveState

    var body: some View {
        let summary = WorkoutsReadout.lastSessionSummary(taggedTail: live.taggedTail(domain: .workouts))
        VStack(alignment: .leading, spacing: 4) {
            ReadoutRow(label: String(localized: "Last session"), value: summary ?? String(localized: "no session yet"))
        }
        .padding(.top, 2)
    }
}

/// The Import & Data Ingest live-readout panel: the last import summary (parser source + version, and the
/// most recent per-stage and day-delta fragment), parsed from the `.dataImport`-tagged log tail the import
/// emitters write, by the pure `ImportReadout`. Binding off the tagged tail mirrors the other app-level
/// panels, so the import layer needs no new published properties. No hardcoded colours; uses the same
/// ReadoutRow tokens as the other panels. No em-dash in any string here.
private struct ImportReadoutPanel: View {
    @ObservedObject var live: LiveState

    var body: some View {
        let summary = ImportReadout.lastImportSummary(taggedTail: live.taggedTail(domain: .dataImport))
        VStack(alignment: .leading, spacing: 4) {
            ReadoutRow(label: String(localized: "Last import"), value: summary ?? String(localized: "no import yet"))
        }
        .padding(.top, 2)
    }
}

/// The Display & Performance live-readout panel: the device-metrics summary (size / size-class / Dynamic
/// Type / orientation / theme) and the latest frame-time summary, parsed from the `.display`-tagged log
/// tail the device-metrics + frame-monitor emitters write, by the pure `DisplayReadout`. Binding off the
/// tagged tail mirrors the other app-level panels, so the monitor needs no new published property. No
/// hardcoded colours; uses the same ReadoutRow tokens as the other panels. No em-dash in any string here.
private struct DisplayReadoutPanel: View {
    @ObservedObject var live: LiveState

    var body: some View {
        let tail = live.taggedTail(domain: .display)
        let metrics = DisplayReadout.deviceMetricsNow(taggedTail: tail)
        let frames = DisplayReadout.frameSummaryNow(taggedTail: tail)
        VStack(alignment: .leading, spacing: 4) {
            ReadoutRow(label: String(localized: "Device metrics"), value: metrics ?? String(localized: "reading…"))
            ReadoutRow(label: String(localized: "Frame summary"), value: frames ?? String(localized: "no window yet"))
        }
        .padding(.top, 2)
    }
}

/// A compact key/value readout row for the Test Centre live panels (Group E/F/G). Mono value so the
/// counts line up; secondary/tertiary tokens so it reads as a diagnostic, not a headline.
private struct ReadoutRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(value).font(StrandFont.mono).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// The mandatory review-before-share sheet (spec sections 9 and 12): shows the exact redacted report.txt
/// the user is about to share, with explicit Share and Cancel. Nothing leaves the device until Share.
private struct ReportReviewSheet: View {
    @ObservedObject var report: TestCentreReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let preview = report.pending?.gate.previewText ?? ""
        return ScreenScaffold(title: "Review before sharing",
                              subtitle: "This is exactly what your report will contain. Nothing leaves \(Platform.deviceNounPhrase) until you tap Share.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                if report.pending?.modeInactive == true {
                    // #1002: the selected profile's test mode is not on, so this bundle carries no capture
                    // for the very thing being reported (the #812 capture_check only grades ACTIVE modes,
                    // so without this the report just looked thin with no explanation). Warn plainly, with
                    // the fix, BEFORE the user ships a report a maintainer can't act on.
                    Text("Heads up: this test mode is off, so the report has no capture for it. For a useful report, turn the mode on, reproduce the problem while wearing the strap, then report again.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NoopCard {
                    ScrollView {
                        Text(preview.isEmpty ? String(localized: "(nothing to share yet)") : preview)
                            .font(StrandFont.mono)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 360)
                }
                HStack(spacing: NoopMetrics.space3) {
                    NoopButton("Cancel", systemImage: "xmark", kind: .secondary) {
                        report.cancel(); dismiss()
                    }
                    NoopButton("Share", systemImage: "square.and.arrow.up", kind: .primary) {
                        report.confirm(); dismiss()
                    }
                }
            }
        }
    }
}
