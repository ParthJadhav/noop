//  LiquidTodayView.swift
//  NOOP · Liquid design language — the Today screen, rebuilt in the liquid finish.
//
//  This is the FULL Today, re-created faithfully from the locked mockup
//  (scratchpad/liquid-metal-home.html): sky title + record/add/battery controls,
//  the three scores as liquid vessels with source pills, the live heart-rate
//  thread, the five "your cards" as liquid chips, a greeting + readiness pills,
//  Synthesis, Recovery Vitals, a Key Metrics grid (incl. steps), Last Workouts
//  and Data Sources. Every value binds to the SAME real data the classic
//  TodayView reads (accessors verified against TodayView.swift), and every tap
//  routes to the same public destination. The sky is a fixed, full-bleed
//  background (edge-to-edge under the status bar, does not scroll).

import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

struct LiquidTodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shared with the real Today's card-customise editor so the two stay in sync.
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""

    // async-loaded via the confirmed Repository accessors
    @State private var restScore: Double?          // sleep_performance, day-keyed
    @State private var stress: Double?             // StressModel(...).score, 0–3
    @State private var fitnessAge: Double?         // exploreSeries("fitness_age").last
    @State private var vitality: Double?           // exploreSeries("vitality").last
    @State private var stepsEst: Double?           // steps_est, day-keyed to the selected day (fallback)
    @State private var hrValues: [Double] = []     // hrBuckets since midnight → 5-min means
    @State private var workouts: [WorkoutRow] = [] // newest-first

    // sheets / expanders
    @State private var guideSection: ScoreSection?
    @State private var showCustomise = false
    @State private var showSettings = false
    @State private var showSupport = false
    @State private var synthesisExpanded = false
    @State private var showLiveSession = false

    /// Live Sessions (silent guardian) beta gate — the SAME key the Settings toggle writes. Default ON
    /// (the entry is BETA-labelled in-UI); off removes the Start-session control entirely.
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true

    // day navigation (0 = today, 1 = yesterday, …)
    @State private var selectedDayOffset = 0
    @State private var showDayPicker = false

    // PERF: the body was rescanning repo.days (599 days) ~23× per pass for displayDay and ~3× for
    // readiness on EVERY re-render (every HR notify, every canvas frame that invalidates, every scroll).
    // Resolve both ONCE per data/day change in load() and read the cache in body (O(1)).
    @State private var cachedDisplayDay: DailyMetric?
    @State private var cachedReadiness: ReadinessEngine.Readiness?
    /// The recovery-INDEPENDENT prior-day vitals carry (HRV / RHR / respiratory), resolved ONCE in load()
    /// alongside cachedDisplayDay. Fixes the v8 rollover blank: after 04:00, before tonight's sleep scores,
    /// today's row has no vitals yet, so these fall back to the last night that recorded them. Never
    /// resolved in body — body rescans repo.days ~23× per pass, and this cache keeps that read O(1).
    @State private var cachedVitalsDay: DailyMetric?
    /// Flips true once the first load() completes. Until then the hero gauges + sky render STATIC so the
    /// launch data-churn (refresh publish + BLE/HR notifies) isn't fighting 4 live canvases + CoreMotion.
    @State private var dataLoaded = false

    // Custom liquid pull-to-refresh: a vessel that FILLS as you drag, releases into a refresh (replaces
    // the system spinner). Driven by the scroll's top overscroll offset.
    @State private var pullY: CGFloat = 0
    @State private var refreshArmed = false
    @State private var refreshing = false
    @State private var pullHaptic = 0
    private let pullThreshold: CGFloat = 80

    /// Mock Vitality purple (#9b7bff) has no exact StrandPalette token in this theme.
    private let liquidPurple = Color(.sRGB, red: 0x9b / 255, green: 0x7b / 255, blue: 0xff / 255, opacity: 1)
    /// The liquid heart pink (matches LiquidThread's default + the mockup #ff6b81).
    private let liquidHeart = Color(.sRGB, red: 1, green: 107 / 255, blue: 129 / 255, opacity: 1)
    /// Hero card fill: a translucent near-black so it floats over the sky (mock rgba(13,14,20,.78)).
    private let heroFill = Color(.sRGB, red: 13 / 255, green: 14 / 255, blue: 20 / 255, opacity: 0.80)

    // MARK: - Day navigation (ported from classic Today: swipe + calendar, day-keyed reads)

    /// The logical day the selector resolves to (offset 0 = today's logical day, rolls at 04:00).
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs key on. At offset 0 follows repo.today?.day.
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }
    /// The DailyMetric shown for the selected day — read from the cache resolved in load() (was an
    /// O(days) `.last(where:)` scan referenced ~23× per body pass; now O(1)).
    private var displayDay: DailyMetric? { cachedDisplayDay }
    /// The prior-day vitals carry (see `cachedVitalsDay`), read O(1) from the cache. Non-nil only at
    /// offset 0 (today); a navigated past day carries nothing (its own row is the whole story).
    private var vitalsDay: DailyMetric? { cachedVitalsDay }

    /// The actual O(days) resolution. Offset 0 prefers live repo.today; past offsets look up. Run ONCE
    /// per data/day change from load(), never from body.
    private func resolveDisplayDay() -> DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }
    /// How far back navigation can go (whole days from the earliest banked day to today).
    private var earliestDayOffset: Int {
        Self.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                          todayKey: Repository.logicalDayKey(Date()))
    }
    /// The big header title: Today / Yesterday / weekday for older days.
    private var dayTitle: String {
        switch selectedDayOffset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default:
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEEE"
            return f.string(from: selectedLogicalDay)
        }
    }
    /// Two-way binding for the graphical calendar: reads the shown day, writes back an offset.
    private var dayPickerBinding: Binding<Date> {
        Binding(
            get: { selectedLogicalDay },
            set: { newValue in
                selectedDayOffset = Self.pickedDayOffset(pickedDate: newValue,
                                                         anchorLogicalDay: Repository.logicalDay(Date()))
                showDayPicker = false
            }
        )
    }
    /// Horizontal swipe between days (left = older, right = newer), clamped to [today, earliest].
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                let delta = dx < 0 ? 1 : -1
                let next = Self.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                 maxOffset: earliestDayOffset)
                guard next != selectedDayOffset else { return }
                withAnimation(StrandMotion.interactive) { selectedDayOffset = next }
            }
    }

    static func clampedDayOffset(current: Int, delta: Int, maxOffset: Int) -> Int {
        min(max(0, maxOffset), max(0, current + delta))
    }
    static func maxDayOffset(earliestDayKey: String?, todayKey: String) -> Int {
        guard let earliestKey = earliestDayKey,
              let earliest = dayKeyParser.date(from: earliestKey),
              let today = dayKeyParser.date(from: todayKey) else { return 0 }
        let gap = Calendar.current.dateComponents([.day],
                                                  from: Calendar.current.startOfDay(for: earliest),
                                                  to: Calendar.current.startOfDay(for: today)).day ?? 0
        return max(0, gap)
    }
    static func pickedDayOffset(pickedDate: Date, anchorLogicalDay: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: pickedDate),
                                      to: cal.startOfDay(for: anchorLogicalDay)).day ?? 0
        return max(0, days)
    }
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Scroll-offset probe at the very top (before padding), so its minY in the scroll's
                // coordinate space reads the top OVERSCROLL: ~0 at rest, positive as you pull down.
                GeometryReader { g in
                    Color.clear.preference(key: PullOffsetKey.self,
                                           value: g.frame(in: .named(Self.pullSpace)).minY)
                }
                .frame(height: 0)

                liquidRefreshIndicator   // grows in the revealed space; a vessel filling with the pull

                VStack(alignment: .leading, spacing: 12) {
                    scene
                    heartRateSection
                    yourCardsSection
                    synthesisSection
                    recoveryVitalsSection
                    keyMetricsSection
                    lastWorkoutsSection
                    dataSourcesSection
                    Color.clear.frame(height: 90) // floating tab-bar clearance
                }
                .padding(.horizontal, 16)
                .padding(.top, 30) // sit the title lower into the sky, not jammed under the status bar
            }
            #if os(macOS)
            // Keep the phone-shaped column readable + centred on the wide mac detail pane. The sky is a
            // ScrollView background (full-bleed), so constraining the content column here doesn't touch it.
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            #endif
        }
        .coordinateSpace(name: Self.pullSpace)
        .onPreferenceChange(PullOffsetKey.self) { handlePull($0) }
        // The sky is a FIXED full-bleed backdrop drawn behind the scroll content, edge-to-edge under the
        // status bar. A ScrollView background does not scroll with the content, so pulling down never
        // moves the sky (the exact behaviour the scaffold uses on the classic Today).
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                StrandPalette.surfaceBase
                // Reduce-motion (and low-power) users get the same sky posed still — no twinkle/breath.
                // Also static until the first data load settles, so launch isn't fighting a live sky too.
                Group {
                    if reduceMotion || !dataLoaded { LiquidSkyStatic(hour: liveHour) }
                    else { LiquidSky(hour: liveHour) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 340, alignment: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .ignoresSafeArea()
        }
        // Swipe left/right to change DAYS (WHOOP-style). Tab-swipe is disabled on Today in RootTabView so
        // this owns the horizontal gesture here.
        .simultaneousGesture(daySwipeGesture)
        // A light tick when the day changes (swipe or calendar pick) — the WHOOP-style day nav should
        // feel physical ("every tiny little thing").
        .liquidSelectionHaptic(trigger: selectedDayOffset)
        // A firm tick when the pull passes the release threshold (the custom liquid refresh).
        .liquidMediumHaptic(trigger: pullHaptic)
        .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)") { await load() }
        .sheet(item: $guideSection) { section in
            NavigationStack { ScoringGuideView(initialSection: section, onClose: { guideSection = nil }) }
        }
        .sheet(isPresented: $showCustomise) {
            DashboardCardsEditorSheet(selectionRaw: $dashboardCardsRaw)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .liquidSheetDoneChrome { showSettings = false }
            }
        }
        // The heart → the (optional) Support sheet: NOOP is free forever, donations just help it keep moving.
        .sheet(isPresented: $showSupport) {
            NavigationStack {
                SupportView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .liquidSheetDoneChrome { showSupport = false }
            }
        }
        // Live Session (silent guardian, beta): the in-session screen owns the whole display — full
        // screen on iOS (nothing should compete with the ring mid-workout), a sheet on macOS where
        // fullScreenCover doesn't exist.
        .liveSessionCover(isPresented: $showLiveSession)
        #if os(macOS)
        // Hide the mac window toolbar's vibrant material so the full-bleed day-of-sky reads dark + edge-to-edge
        // at the top instead of the white scroll-under-titlebar wash.
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
    }

    // MARK: - Liquid pull-to-refresh

    static let pullSpace = "liqTodayScroll"

    /// Reserves the revealed space at the top and shows a vessel that fills with the pull, then sloshes
    /// while the refresh runs.
    private var liquidRefreshIndicator: some View {
        let progress = min(1, max(0, pullY / pullThreshold))
        return ZStack {
            if refreshing {
                LiquidVessel(value: 0.6, tint: liquidHeart, animated: true)
                    .frame(width: 34, height: 34)
            } else if pullY > 2 {
                LiquidVessel(value: progress, tint: liquidHeart, animated: false)
                    .frame(width: 30, height: 30)
                    .opacity(progress)
                    .scaleEffect(0.7 + 0.3 * progress)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: refreshing ? 64 : min(pullY, pullThreshold * 1.15))
        .animation(.easeOut(duration: 0.22), value: refreshing)
    }

    /// Arm the refresh once the pull passes the threshold; FIRE it when the finger releases (the pull
    /// springs back toward zero). Guarded so it can't double-fire or re-trigger mid-refresh.
    private func handlePull(_ y: CGFloat) {
        pullY = max(0, y)
        guard !refreshing else { return }
        if pullY >= pullThreshold, !refreshArmed {
            refreshArmed = true
            pullHaptic &+= 1
        }
        if refreshArmed, pullY < 6 {
            refreshArmed = false
            refreshing = true
            Task {
                await repo.refresh()
                await load()
                try? await Task.sleep(nanoseconds: 350_000_000)   // let the fill read as "done"
                withAnimation(.easeOut(duration: 0.25)) { refreshing = false }
            }
        }
    }

    // MARK: - Scene (sky title + controls + hero)

    private var scene: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Button { showDayPicker = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dayTitle)
                            .font(StrandFont.rounded(28))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 10, y: 1)
                        Text(dateLine)
                            .font(StrandFont.caption)
                            .foregroundStyle(.white.opacity(0.78))
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(dayTitle). Tap to pick a day, swipe to change day.")
                .popover(isPresented: $showDayPicker) {
                    DatePicker("", selection: dayPickerBinding, in: ...Repository.logicalDay(Date()),
                               displayedComponents: [.date])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(12)
                        .frame(minWidth: 320, minHeight: 360)
                        .liquidPopoverAdaptation()
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    // Support / donate — a tap opens the (optional) support sheet. NOOP is free forever.
                    Button { showSupport = true } label: {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(StrandPalette.chargeColor)
                            .frame(width: 34, height: 34)
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 1)
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Support NOOP. It's free; donations are optional and help development.")
                    // Profile pic (the one set in Settings) → opens Settings, matching the classic Today.
                    Button { showSettings = true } label: {
                        ProfileAvatarView(imageData: profile.avatarImageData, size: 34)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Profile and settings")
                    LiquidAddButton()
                    LiquidBatteryButton()
                }
            }
            // Subtle NOOP wordmark in the sky between header and hero. Perfectly centred (a letter row has
            // no trailing tracking gap the way `Text(...).tracking()` does), with a tap easter egg.
            LiquidWordmark()
                .padding(.top, 30)
            heroCard.padding(.top, 22)
            if liveSessionsBeta {
                liveSessionStartRow.padding(.top, 10)
            }
        }
    }

    /// One-tap Live Session start (silent guardian, beta) — sits directly under the hero scores, the
    /// Charge its band is gated on. Same translucent chrome as the hero card so it reads as part of the
    /// sky scene, quiet by design.
    private var liveSessionStartRow: some View {
        Button { showLiveSession = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricCyan)
                Text("Start session")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("BETA")
                    .font(StrandFont.overlineScaled(8.5)).tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2.5)
                    .background(Capsule().fill(.white.opacity(0.05))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(heroFill)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.11), lineWidth: 1))
            )
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Start a live session. Beta. Silent strap coaching against today's Charge.")
    }

    private var heroCard: some View {
        HStack(alignment: .top, spacing: 4) {
            HeroScoreCell(label: "Charge", score: displayDay?.recovery, tint: StrandPalette.chargeColor,
                          pill: "WHOOP", animated: dataLoaded, onGuide: { guideSection = .charge })
            HeroScoreCell(label: "Effort", score: displayDay?.strain, tint: StrandPalette.effortColor,
                          pill: nil, animated: dataLoaded, onGuide: { guideSection = .effort })
            HeroScoreCell(label: "Rest", score: restScore, tint: StrandPalette.restColor,
                          pill: "WHOOP", animated: dataLoaded, onGuide: { guideSection = .rest })
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(heroFill)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.11), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
        )
    }

    // MARK: - Heart rate

    private var heartRateSection: some View {
        VStack(spacing: 8) {
            sectionHead("HEART RATE", trailing: "Live")
            // #979: the whole-day HR trend (Deep Timeline) still exists but was buried behind Metrics →
            // Show all → Deep Timeline. Make the live HR card a one-tap route into it, with a visible
            // "Full day" affordance so it's discoverable again. (This comment used to claim the Deep
            // Timeline already drew sleep + activity bands — it didn't at the time; the #979 spin-off
            // added that parity in FullDayChartView.)
            NavigationLink { FullDayChartView() } label: {
                card {
                    VStack(spacing: 10) {
                        // Isolated leaf: it observes LiveState so the ~1 Hz HR notifies re-render ONLY
                        // this card, never the whole Today. Shows the current bpm live with a rolling
                        // beat-by-beat trace; falls back to today's banked 5-minute trace when idle.
                        LiquidLiveHR(tint: liquidHeart, fallback: hrValues, animated: dataLoaded)
                        HStack(spacing: 4) {
                            Spacer()
                            Text("Full day").font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(StrandPalette.accent)
                        }
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityHint("Opens the full-day heart rate timeline")
        }
    }

    // MARK: - Your cards

    private var yourCardsSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("YOUR CARDS").font(StrandFont.overline).tracking(1.6)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Button { showCustomise = true } label: {
                    Text("CUSTOMISE").font(StrandFont.overlineScaled(11)).tracking(1.0)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)

            // Data-driven off the SAME @AppStorage the CUSTOMISE editor writes, so add / remove /
            // reorder in Customise reflects on the home screen live.
            ForEach(DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)) { card in
                liquidCard(for: card)
            }
        }
    }

    /// One "Your cards" row for a given card type — honours the user's CUSTOMISE selection + order.
    /// Wired cards show real values; the rest render "–" for now (they still appear, so add/remove/
    /// reorder is reflected). stress → Stress screen, sleep → Sleep, everything else → Health.
    @ViewBuilder
    private func liquidCard(for card: DashboardCard) -> some View {
        switch card {
        case .stress:
            cardLink(dest: StressView(), title: card.title, sub: card.subtitle,
                     value: stressText, tint: StrandPalette.accent, frac: fracOver(stress, 3))
        case .fitnessAge:
            cardLink(dest: metricDetail("fitness_age"), title: card.title, sub: card.subtitle,
                     value: unitText(fitnessAge, card.unit), tint: StrandPalette.chargeColor, frac: 0.5)
        case .vitality:
            cardLink(dest: metricDetail("vitality"), title: card.title, sub: card.subtitle,
                     value: intText(vitality), tint: liquidPurple, frac: frac(vitality))
        case .hrv:
            cardLink(dest: metricDetail("hrv"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.avgHrv, card.unit), tint: StrandPalette.metricCyan,
                     frac: fracOver(displayDay?.avgHrv, 120))
        case .restingHr:
            cardLink(dest: metricDetail("rhr"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.restingHr.map(Double.init), card.unit),
                     tint: StrandPalette.metricRose, frac: fracOver(displayDay?.restingHr.map(Double.init), 100))
        case .respiratory:
            cardLink(dest: metricDetail("resp_rate"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.respRateBpm, card.unit, decimals: 1),
                     tint: StrandPalette.accent, frac: fracOver(displayDay?.respRateBpm, 24))
        case .steps:
            cardLink(dest: metricDetail("steps_est"), title: card.title, sub: card.subtitle,
                     value: stepsText, tint: StrandPalette.metricCyan, frac: fracOver(stepCount, 10000))
        case .bloodOxygen:
            // Not wired to a real read yet — render EMPTY (not half-full) so it doesn't imply a reading.
            cardLink(dest: metricDetail("spo2"), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricCyan, frac: nil)
        case .skinTemp:
            cardLink(dest: metricDetail("skin_temp"), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricAmber, frac: nil)
        case .calories:
            cardLink(dest: metricDetail("active_kcal"), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricAmber, frac: nil)
        case .sleep:
            cardLink(dest: SleepView(), title: card.title, sub: card.subtitle,
                     value: sleepText, tint: StrandPalette.restColor, frac: fracOver(displayDay?.totalSleepMin, 480))
        case .hydration:
            cardLink(dest: HydrationView(), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricCyan, frac: nil)
        case .coupled:
            // A tap-through to the full Coupled day screen. No value.
            cardLink(dest: CoupledView(), title: card.title, sub: card.subtitle,
                     value: "", tint: StrandPalette.chargeColor, frac: 0.6)
        }
    }

    /// The per-metric detail page (its own data screen with chart + history), looked up by catalog key.
    /// Each card opens ITS metric (2026-07-02: not the shared Health screen). Falls back to Health
    /// only if the key is somehow absent from the catalog.
    @ViewBuilder
    private func metricDetail(_ key: String) -> some View {
        if let m = MetricCatalog.all.first(where: { $0.key == key }) {
            MetricDetailView(metric: m)
        } else {
            HealthView()
        }
    }

    private func cardLink<Dest: View>(dest: Dest, title: String, sub: String,
                                      value: String, tint: Color, frac: Double?) -> some View {
        NavigationLink { dest } label: {
            HStack(spacing: 12) {
                LiquidVessel(value: frac, tint: tint, animated: false).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased()).font(StrandFont.overlineScaled(11)).tracking(1.0)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(sub).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Text(value).font(StrandFont.number(17)).foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            )
        }
        .buttonStyle(LiquidPressStyle())
    }

    // MARK: - Synthesis (greeting + readiness pills + one-liner)

    private var synthesisSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text(greeting).font(StrandFont.rounded(19)).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)   // yield to the pills rather than push them to wrap
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if let word = readinessWord {
                        Text(word)
                            .font(StrandFont.caption.weight(.bold))
                            .foregroundStyle(StrandPalette.chargeColor)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(StrandPalette.chargeColor.opacity(0.14))
                                .overlay(Capsule().strokeBorder(StrandPalette.chargeColor.opacity(0.3), lineWidth: 1)))
                    }
                    HStack(spacing: 5) {
                        Circle().fill(StrandPalette.chargeColor).frame(width: 6, height: 6)
                        Text(displayDay?.recovery != nil ? "Solid" : "Calibrating")
                            .font(StrandFont.caption.weight(.bold))
                            .foregroundStyle(StrandPalette.chargeColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().strokeBorder(StrandPalette.chargeColor.opacity(0.3), lineWidth: 1))
                }
                .fixedSize(horizontal: true, vertical: false)   // pills keep their natural width — no "Calibrating" wrap
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)

            Button { withAnimation(.easeInOut(duration: 0.2)) { synthesisExpanded.toggle() } } label: {
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("SYNTHESIS").font(StrandFont.overline).tracking(1.6)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            Text(synthesisExpanded ? "hide" : "show").font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Text(synthLine).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if synthesisExpanded {
                            Text(readiness.summary).font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    // MARK: - Recovery vitals

    private var recoveryVitalsSection: some View {
        // PER-FIELD, today-first carry: each vital reads today's own value, else falls back to the prior
        // day that recorded it (`vitalsDay`). Coalesce ONCE so the number and its fill fraction agree.
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("RECOVERY VITALS").font(StrandFont.overline).tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    if let line = vitalsProvenanceLine {
                        Text(line).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                vitalRow("Heart-rate variability", unitText(hrv, "ms"),
                         StrandPalette.metricCyan, fracOver(hrv, 120))
                vitalRow("Resting heart rate", unitText(rhr, "bpm"),
                         StrandPalette.metricRose, fracOver(rhr, 100))
                vitalRow("Breaths per minute", unitText(resp, "rpm", decimals: 1),
                         StrandPalette.accent, fracOver(resp, 24))
            }
        }
    }

    private func vitalRow(_ label: String, _ value: String, _ tint: Color, _ frac: Double?) -> some View {
        HStack(spacing: 12) {
            LiquidVessel(value: frac, tint: tint, animated: false).frame(width: 26, height: 26)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    // MARK: - Key metrics grid

    private var keyMetricsSection: some View {
        // HRV / Rest HR tiles share the recovery vitals' per-field today-first carry so they don't blank at
        // the rollover while Recovery/Strain/Sleep stay strictly today's own (they are scored surfaces).
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        return VStack(spacing: 8) {
            sectionHead("KEY METRICS", trailing: "14-day trend")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ktile("Recovery", intText(displayDay?.recovery), "%", StrandPalette.chargeColor, frac(displayDay?.recovery))
                ktile("Strain", intText(displayDay?.strain), "%", StrandPalette.effortColor, frac(displayDay?.strain))
                ktile("Sleep", sleepText, "", StrandPalette.restColor, fracOver(displayDay?.totalSleepMin, 480))
                ktile("HRV", intText(hrv), "ms", StrandPalette.metricCyan, fracOver(hrv, 120))
                ktile("Rest HR", intText(rhr), "bpm", StrandPalette.metricRose, fracOver(rhr, 100))
                ktile("Steps", stepsText, "", StrandPalette.chargeColor, fracOver(stepCount, 10000))
            }
            NavigationLink { MetricExplorerView() } label: {
                Text("Show all metrics").font(StrandFont.subhead).foregroundStyle(StrandPalette.accent)
                    .frame(maxWidth: .infinity).padding(.top, 2)
            }
            .buttonStyle(.plain)
        }
    }

    private func ktile(_ label: String, _ value: String, _ unit: String, _ tint: Color, _ frac: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(StrandFont.overlineScaled(9)).tracking(1.2)
                .foregroundStyle(StrandPalette.textTertiary)
            (Text(value).font(StrandFont.number(17))
                + Text(unit.isEmpty ? "" : " \(unit)").font(StrandFont.caption))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            LiquidTube(frac: frac ?? 0, tint: tint, height: 8, animated: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        )
    }

    // MARK: - Last workouts

    private var lastWorkoutsSection: some View {
        VStack(spacing: 8) {
            sectionHead("LAST WORKOUTS", trailing: "\(workouts.count) total")
            if let w = workouts.first {
                NavigationLink { WorkoutsView() } label: { workoutCard(w) }
                    .buttonStyle(LiquidPressStyle())
            } else {
                card {
                    Text("No workouts yet")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func workoutCard(_ w: WorkoutRow) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkoutSource.displaySport(w.sport)).font(StrandFont.number(15))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(workoutSub(w)).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    (Text(effortText(w.strain)).font(StrandFont.number(15))
                        + Text(" EFFORT").font(StrandFont.overlineScaled(9)))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                LiquidTube(frac: (w.strain ?? 0) / 100, tint: StrandPalette.effortColor, height: 12, animated: false)
            }
        }
    }

    // MARK: - Data sources

    private var dataSourcesSection: some View {
        VStack(spacing: 8) {
            sectionHead("DATA SOURCES", trailing: "Provenance")
            NavigationLink { DataSourcesView() } label: {
                card {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Synced from").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Text("View sources").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        LiquidStrapBatteryRow()
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    // MARK: - Reusable chrome

    private func sectionHead(_ title: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(trailing).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            )
    }

    // MARK: - Data

    private func load() async {
        // Resolve the O(days) lookups ONCE here (not on every body re-render): the selected day and the
        // readiness verdict. Both scan repo.days (up to 599 rows); doing it per-render was the stutter.
        let day = resolveDisplayDay()
        cachedDisplayDay = day
        cachedReadiness = ReadinessEngine.evaluate(days: repo.days, today: day?.day)
        // Prior-day vitals carry, resolved ONCE here (never in body). Bound to today's own key so it can't
        // echo today's still-forming row; only on today (a past day's own row is the whole story).
        let tkey = cachedDisplayDay?.day ?? selectedDayKey
        cachedVitalsDay = (selectedDayOffset == 0) ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let from = Int(dayStart.timeIntervalSince1970)
        // today → midnight..now; a past day → its full 24h (a missing morning reads as empty space).
        let to: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)

        async let restA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stressA = repo.series(key: "stress", source: "my-whoop")
        async let fitA = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vitA = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let stepsA = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        async let hrA = repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
        async let wkA = repo.workoutRows()

        let restSeries = await restA
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // Selected day's Rest; tail fallback only at offset 0 (a past day with no row shows nothing) AND
        // only when the tail night is still fresh. #977: a live 5.0 whose sleep never scores (no overnight
        // gravity ⇒ no sleep_performance point ever written) used to pin Rest to the weeks-old series tail
        // forever while Charge advanced; freshness-gate the tail-fallback so a stale tail falls through to
        // the Rest hero's No-Data/calibrating state (same empty treatment Effort uses) instead of freezing.
        restScore = TodayView.freshRestScore(
            todayValue: restByDay[selectedDayKey], lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value, isTodaySelected: selectedDayOffset == 0,
            todayKey: selectedDayKey)
        // StressModel loops the full history to build its baseline — run it OFF the main actor so a big
        // history doesn't stutter the UI. Snapshot the inputs (value types) into the detached task.
        let storedStress = await stressA
        let daysSnapshot = repo.days
        stress = await Task.detached(priority: .utility) {
            StressModel(days: daysSnapshot, stored: storedStress)?.score
        }.value
        fitnessAge = (await fitA).last?.value   // history-wide latest banked (not day-scoped)
        vitality = (await vitA).last?.value
        // Steps is a DAILY metric, so key it to the SELECTED day (like restScore above), not the history-wide
        // latest. Without this, swiping to a past day with no strap step count showed today's estimate (the
        // `.last` value) instead of that day's. Mirrors the classic Today's stepsEstByDay[selectedDayKey].
        let stepsSeries = await stepsA
        let stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        stepsEst = stepsByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? stepsSeries.last?.value : nil)
        hrValues = (await hrA).map { $0.bpm }
        workouts = await wkA

        // First load done — bring the hero gauges + sky to life now the launch churn has settled.
        if !dataLoaded { withAnimation(.easeIn(duration: 0.4)) { dataLoaded = true } }
    }

    // MARK: - Derived (sync, off repo.today / repo.days)

    /// Cached in load() — ReadinessEngine.evaluate scans the full history and was invoked ~3× per body
    /// pass (readinessWord + synthLine + readiness.summary). The fallback runs only in the brief window
    /// before the first load() populates the cache.
    private var readiness: ReadinessEngine.Readiness {
        cachedReadiness ?? ReadinessEngine.evaluate(days: repo.days, today: cachedDisplayDay?.day)
    }

    private var readinessWord: String? {
        switch readiness.level {
        case .primed: return "Push"
        case .balanced: return "Maintain"
        case .strained, .rundown: return "Rest"
        case .insufficient: return nil
        }
    }

    private var synthLine: String {
        switch readiness.level {
        case .primed: return "You're primed. A hard session should land well today."
        case .balanced: return "You're in a good spot for training."
        case .strained: return "Signals are down a touch. Keep it easy today."
        case .rundown: return "Several recovery signals are down. Prioritise rest today."
        case .insufficient: return "Still learning your baseline. A few more nights and this fills in."
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }

    private var stepCount: Double? { displayDay?.steps.map(Double.init) ?? stepsEst }

    private var liveHour: Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    // MARK: - Formatting

    private func frac(_ v: Double?) -> Double? { v.map { max(0, min(1, $0 / 100)) } }
    private func fracOver(_ v: Double?, _ over: Double) -> Double? { v.map { max(0, min(1, $0 / over)) } }
    private func intText(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "–" }

    private func unitText(_ v: Double?, _ unit: String, decimals: Int = 0) -> String {
        guard let v else { return "–" }
        let n = decimals > 0 ? String(format: "%.\(decimals)f", v) : String(Int(v.rounded()))
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    private var stressText: String { stress.map { String(Int($0.rounded())) } ?? "Calibrating" }

    private var sleepText: String {
        guard let m = displayDay?.totalSleepMin else { return "–" }
        return "\(Int(m) / 60)h \(Int(m) % 60)m"
    }

    private var stepsText: String {
        guard let s = stepCount else { return "–" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: Int(s))) ?? "\(Int(s))"
    }

    // The user's Effort display scale (#268), 0–100 by default or the WHOOP 0–21 axis if chosen — the SAME
    // preference the Workouts screen + Trends read, so a workout's Effort number is identical everywhere.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private func effortText(_ s: Double?) -> String {
        guard let s else { return "–" }
        // Route through the shared formatter instead of hardcoding *21: a default (0–100) user was shown the
        // WHOOP-scaled number here while the hero + Workouts table showed 0–100, two numbers for one workout.
        return UnitFormatter.effortDisplay(s, scale: effortScale)
    }

    private func workoutSub(_ w: WorkoutRow) -> String {
        var parts: [String] = []
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        parts.append("\(Int(secs / 60)) min")
        if let dm = w.distanceM, dm > 0 { parts.append(String(format: "%.1f km", dm / 1000)) }
        if let k = w.energyKcal { parts.append("\(Int(k.rounded())) kcal") }
        return parts.joined(separator: " · ")
    }

    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: selectedLogicalDay)
    }

    /// Provenance caption for the recovery-vitals card, keyed on the row a vital actually came from — NOT a
    /// hardcoded "yesterday". If ANY shown vital fell back to `vitalsDay` (today's own value is nil and the
    /// carried row supplies it), it stamps that row's date via the shared `TodayView.carriedCaption`, so a
    /// genuine post-rollover carry reads "Last night · <date>" and a weeks-old carry relabels to
    /// "Latest sleep · <date>" (#779) instead of a false "Last night". When every shown vital is today's
    /// own (or there's nothing to carry), it returns nil — the card must not claim "Last night" at all.
    private var vitalsProvenanceLine: String? {
        guard let carried = vitalsDay else { return nil }
        let carriedHrv = displayDay?.avgHrv == nil && carried.avgHrv != nil
        let carriedRhr = displayDay?.restingHr == nil && carried.restingHr != nil
        let carriedResp = displayDay?.respRateBpm == nil && carried.respRateBpm != nil
        guard carriedHrv || carriedRhr || carriedResp else { return nil }
        return TodayView.carriedCaption(priorDayKey: carried.day,
                                        todayKey: displayDay?.day ?? selectedDayKey)
    }
}

/// Carries the Today scroll's top overscroll offset up to the view for the custom liquid pull-to-refresh.
private struct PullOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - NOOP wordmark (centred, with a tap easter egg)

/// The subtle NOOP wordmark. Built as a row of letters (not `Text(...).tracking()`, which adds a
/// trailing gap after the last glyph and pushes the word off-centre), so it sits DEAD centre. Tap it
/// for a little easter egg: it plays one of several random one-shot animations — wiggle, shake, flip,
/// spin, bounce, or a jelly squash — with a light haptic.
private struct LiquidWordmark: View {
    @State private var rot = 0.0      // z-rotation (wiggle / spin)
    @State private var scaleX = 1.0   // horizontal scale (jelly squash)
    @State private var scaleY = 1.0   // vertical scale (bounce / jelly)
    @State private var dx = 0.0       // horizontal offset (shake)
    @State private var flip = 0.0     // y-axis 3D flip
    @State private var token = 0      // drives the tap haptic

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array("NOOP".enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(StrandFont.rounded(16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
        .rotationEffect(.degrees(rot))
        .scaleEffect(x: scaleX, y: scaleY)
        .offset(x: dx)
        .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .contentShape(Rectangle())
        .onTapGesture { playRandomEgg() }
        .liquidTapHaptic(trigger: token)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// The easter egg: one of several one-shot animations at random. The oscillating ones (wiggle/shake/
    /// squash) kick the value to an extreme then let an under-damped spring settle it back through zero,
    /// which reads as a natural wobble without hand-authored keyframes.
    private func playRandomEgg() {
        token &+= 1
        switch Int.random(in: 0..<6) {
        case 0: // wiggle
            rot = -14
            withAnimation(.spring(response: 0.5, dampingFraction: 0.28)) { rot = 0 }
        case 1: // shake
            dx = -12
            withAnimation(.spring(response: 0.45, dampingFraction: 0.26)) { dx = 0 }
        case 2: // flip
            withAnimation(.easeInOut(duration: 0.6)) { flip += 360 }
        case 3: // spin
            withAnimation(.easeInOut(duration: 0.55)) { rot += 360 }
        case 4: // bounce
            scaleX = 1.28; scaleY = 1.28
            withAnimation(.spring(response: 0.5, dampingFraction: 0.42)) { scaleX = 1; scaleY = 1 }
        default: // jelly (squash + stretch)
            scaleX = 1.35; scaleY = 0.7
            withAnimation(.spring(response: 0.5, dampingFraction: 0.3)) { scaleX = 1; scaleY = 1 }
        }
    }
}

// MARK: - Hero score cell (count-up number over a filling vessel, tap-to-splash)

/// One of the three hero scores (Charge / Effort / Rest). The vessel fills from empty and the number
/// COUNTS UP to the value when data lands; tapping the gauge itself splashes (the number is
/// hit-transparent so the tap reaches the vessel). The label row taps through to the scoring guide.
private struct HeroScoreCell: View {
    let label: String
    let score: Double?            // 0–100 (nil = no data yet)
    let tint: Color
    let pill: String?
    let animated: Bool
    let onGuide: () -> Void

    @State private var shown: Double = 0

    private var frac: Double? { score.map { max(0, min(1, $0 / 100)) } }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                LiquidVessel(value: frac, tint: tint, animated: animated)
                    .frame(width: 96, height: 96)
                Group {
                    if score != nil {
                        CountUpNumber(value: shown, font: StrandFont.rounded(26))
                    } else {
                        Text("–").font(StrandFont.rounded(26))
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsHitTesting(false)   // taps fall through to the vessel → splash
            }
            Button(action: onGuide) {
                HStack(spacing: 3) {
                    Text(label.uppercased()).font(StrandFont.overline).tracking(1.6)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).opacity(0.6)
                }
                .foregroundStyle(StrandPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(label), \(score.map { String(Int($0.rounded())) } ?? "no data yet"). See how it is scored."))
            if let pill {
                Text(pill)
                    .font(StrandFont.overlineScaled(8.5)).tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2.5)
                    .background(Capsule().fill(.white.opacity(0.05))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)))
            } else {
                Color.clear.frame(height: 18) // keep the three labels vertically aligned
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { rollTo(score) }
        .onChangeCompat(of: score) { v in rollTo(v) }
    }

    private func rollTo(_ v: Double?) {
        guard let v else { shown = 0; return }
        withAnimation(.easeOut(duration: 0.9)) { shown = v }   // counts up in step with the vessel filling
    }
}


// MARK: - Scene controls (LiveState-isolated leaves)

/// Quick-actions "+" button. Tap → the shell's quick-action menu.
private struct LiquidAddButton: View {
    @EnvironmentObject var router: NavRouter
    var body: some View {
        Button { router.requestQuickActions() } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.16)))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Quick actions")
    }
}

/// The live heart-rate readout leaf. Owns LiveState so the ~1 Hz HR notifies re-render ONLY this card,
/// never the whole Today (the isolation the classic Today depends on). Keeps its own rolling buffer of
/// live samples, shows the current bpm live with a beat-by-beat trace, and falls back to today's banked
/// 5-minute trace when the strap isn't streaming.
private struct LiquidLiveHR: View {
    var tint: Color
    var fallback: [Double]        // today's banked 5-minute buckets — shown when there's no live stream
    var animated: Bool

    @EnvironmentObject private var live: LiveState
    @State private var samples: [Double] = []
    @State private var beat = false
    private let maxSamples = 90   // ~1.5 min of 1 Hz live HR, enough to read the shape

    private var isLive: Bool { live.connected && samples.count >= 2 }
    private var series: [Double] { isLive ? samples : fallback }
    private var bigBpm: Int? {
        if let hr = live.heartRate, hr > 0, live.connected { return hr }
        if let last = fallback.last { return Int(last.rounded()) }
        return nil
    }
    private var subtitle: String {
        if isLive { return "Live · beat by beat" }
        if fallback.count >= 2 { return "5-minute average · since midnight" }
        return live.connected ? "Waiting for the strap" : "Strap not connected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BEATS PER MINUTE").font(StrandFont.overline).tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                if isLive {
                    // A gentle heartbeat dot that pulses with each incoming sample.
                    Circle().fill(tint).frame(width: 7, height: 7)
                        .scaleEffect(beat ? 1.35 : 0.85)
                        .opacity(beat ? 1 : 0.45)
                        .animation(.easeOut(duration: 0.28), value: beat)
                        .padding(.trailing, 2)
                }
                if let hr = bigBpm {
                    (Text("\(hr)").font(StrandFont.rounded(22)).monospacedDigit()
                        + Text(" bpm").font(StrandFont.caption))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: hr)
                }
            }
            if series.count >= 2 {
                LiquidThread(bpm: series, tint: tint, height: 92, animated: animated)
                HStack {
                    stat("Min", series.min())
                    Spacer()
                    stat("Avg", series.reduce(0, +) / Double(series.count))
                    Spacer()
                    stat("Max", series.max())
                }
            } else {
                Text(live.connected ? "Waiting for a live heartbeat…" : "Connect your strap to see live heart rate")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        }
        .onAppear { if samples.isEmpty, let hr = live.heartRate, hr > 0 { samples = [Double(hr)] } }
        .onChangeCompat(of: live.heartRate) { hr in
            guard let hr, hr > 0 else { return }
            samples.append(Double(hr))
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
            beat.toggle()
        }
    }

    private func stat(_ label: String, _ v: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(v.map { String(Int($0.rounded())) } ?? "–")
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// Strap-battery ring. Owns LiveState. Tap → Devices.
private struct LiquidBatteryButton: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var router: NavRouter
    var body: some View {
        Button { router.openDevices() } label: {
            ZStack {
                Circle().fill(Color(.sRGB, red: 10 / 255, green: 11 / 255, blue: 16 / 255, opacity: 0.5))
                Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1)
                if let pct = live.batteryPct {
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, pct / 100)))
                        .stroke(ringColor(pct), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2.5)
                    Text("\(Int(pct.rounded()))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                    if live.charging == true {
                        // #972: the default Today never surfaced charging state — only the % ring. A small
                        // bolt over the ring gives the same signal as the "· Charging" text on Mac/Android.
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(StrandPalette.chargeColor)
                            .offset(y: -10)
                    }
                } else {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(batteryAccessibility)
    }
    private var batteryAccessibility: String {
        let base = live.batteryPct.map { "Strap battery \(Int($0.rounded())) percent" } ?? "Strap battery"
        return live.charging == true ? base + ", charging" : base
    }
    private func ringColor(_ p: Double) -> Color {
        p < 15 ? StrandPalette.statusCritical : p < 35 ? StrandPalette.statusWarning : StrandPalette.chargeColor
    }
}

/// The strap-battery readout inside the Data Sources card. Owns LiveState; display-only.
private struct LiquidStrapBatteryRow: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        if live.connected, let pct = live.batteryPct {
            HStack {
                Text("Strap battery").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                // #972: append "· Charging"; #992: append the "~X days left" runtime the v8 redesign dropped.
                Text(batteryText(pct: pct))
                    .font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    /// "87%" plus a trailing "· Charging" (#972) or "· ~9 days left" runtime (#992), matching the Settings /
    /// Mac / Android pill and the classic Today badge.
    private func batteryText(pct: Double) -> String {
        let base = "\(Int(pct.rounded()))%"
        if live.charging == true { return "\(base) · Charging" }
        if let est = estimateText { return "\(base) · \(est)" }
        return base
    }

    /// #992: the v8 Liquid redesign dropped the "~X days left" estimate the classic Today showed (#713).
    /// Reproduced verbatim from `TodayView.estimateText`: under 48 h show hours, at two days or more round to
    /// days; nil (no banked discharge yet, or charging) hides it, so the row only ever shows an estimate we trust.
    private var estimateText: String? {
        guard live.charging != true, let est = live.batteryEstimate else { return nil }
        let hours = est.hoursRemaining
        guard hours.isFinite, hours > 0 else { return nil }
        if hours < 48 {
            return String(localized: "~\(Int(hours.rounded()))h left")
        }
        let days = Int((hours / 24).rounded())
        return days == 1
            ? String(localized: "~1 day left")
            : String(localized: "~\(days) days left")
    }
}

// MARK: - Cross-platform chrome helpers
//
// The liquid Today is shared with the macOS target now (the mac split-view shell hosts it too). A few of
// its chrome modifiers are iOS-only, so they are wrapped here: `topBarTrailing` + `navigationBarTitleDisplayMode`
// don't exist on macOS, and `presentationCompactAdaptation` is an iOS phone-width concern. These keep the
// exact iOS behaviour while giving macOS the platform-correct equivalent.
private extension View {
    /// A sheet's trailing "Done" button (inline title on iOS; the confirmation-action toolbar slot on macOS).
    @ViewBuilder func liquidSheetDoneChrome(done: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: done).foregroundStyle(StrandPalette.accent)
                }
            }
        #else
        self.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done).foregroundStyle(StrandPalette.accent)
            }
        }
        #endif
    }

    /// Keep a popover a popover in compact width (iOS 16.4+); a no-op on macOS where popovers never adapt.
    @ViewBuilder func liquidPopoverAdaptation() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
        #else
        self
        #endif
    }

    /// Present the Live Session screen: fullScreenCover on iOS (the guardian owns the display mid-
    /// workout), a plain sheet on macOS where fullScreenCover doesn't exist. The session view calls
    /// `onClose` itself once the summary is dismissed.
    @ViewBuilder func liveSessionCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #else
        self.sheet(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #endif
    }
}
