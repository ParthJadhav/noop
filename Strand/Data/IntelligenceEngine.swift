import Foundation
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// On-device "intelligence": computes recovery / day-strain / sleep from the raw strap streams using
/// the same model shape WHOOP uses (HRV vs personal baseline ~60%, resting HR ~20%, sleep ~15%,
/// respiration ~5%; strain 0–21 from cardiovascular load). This is what makes NOOP independent of
/// WHOOP's cloud — for any day the strap collected raw data with NOOP connected, NOOP scores it
/// itself rather than relying on the values WHOOP computed in the imported CSV.
@MainActor
final class IntelligenceEngine: ObservableObject {
    private let repo: Repository
    private let profile: ProfileStore
    private let deviceId: String

    @Published var results: [Computed] = []      // newest first
    @Published var computing = false
    @Published var note: String?

    struct Computed: Identifiable {
        let day: String
        let recovery: Double?
        let strain: Double?
        let sleepMin: Double?
        let hrv: Double?
        let rhr: Int?
        var id: String { day }
    }

    init(repo: Repository, profile: ProfileStore, deviceId: String) {
        self.repo = repo; self.profile = profile; self.deviceId = deviceId
    }

    /// Median of a list (0 when empty) — used to denoise the 7-day resting-HR for Fitness Age.
    static func medianOf(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// The Saturday on-or-before a "yyyy-MM-dd" local-day string — the weekly key Fitness Age writes to.
    static func saturdayKey(onOrBefore dayStr: String) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let fmt = DateFormatter(); fmt.calendar = cal; fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: dayStr) else { return dayStr }
        let back = cal.component(.weekday, from: d) % 7   // Sat(7)→0, Sun(1)→1 … Fri(6)→6
        let sat = cal.date(byAdding: .day, value: -back, to: d) ?? d
        return fmt.string(from: sat)
    }

    /// UserDefaults flag guarding the one-shot #313 full-history Effort rescore (below). Set once the
    /// pass completes so it never re-runs.
    static let effortRescoreFlagKey = "intelligence.effortRescore.v313.done"

    /// One-shot, on-upgrade FULL-history Effort rescore (#313 PART B). The Effort hero gauge + numbers
    /// moved from the old 0–21 axis to NOOP's own 0–100 axis. On-device computed rows since v2.6.1
    /// already store 0–100, but rows the engine computed on an OLDER build (capped at `maxDays` per run,
    /// so deep history was never revisited) may still hold 0–21 strain.
    ///
    /// The SAFE fix is to recompute strain FROM SOURCE for every day with raw HR — those regenerate at
    /// 0–100 with NO double-rescale risk — rather than a blind `strain*21→100` multiply that would
    /// double-rescale the large population already on 0–100 (→ ~0–476). We do that by running the normal
    /// `analyzeRecent` once with the `maxDays` cap lifted to the full history, then persist a flag so it
    /// runs exactly once. IMPORTED rows are never rewritten here (the engine only ever writes under the
    /// "-noop" computed source) — those are handled by re-import. A day already on 0–100 is recomputed
    /// from the same raw HR and lands on 0–100 again: UNCHANGED axis (verified by test).
    func runEffortRescoreIfNeeded(historyDays: Int = 4000) async {
        guard !UserDefaults.standard.bool(forKey: Self.effortRescoreFlagKey) else { return }
        await analyzeRecent(maxDays: historyDays)
        // Only mark done if the pass actually completed (wasn't skipped because another tick held the
        // `computing` lock). `computing` is false here once analyzeRecent's `defer` has run; a skipped
        // call returns with `note` unset by it. Use the lock state: if a concurrent run was in progress
        // the flag stays unset so the next launch retries — cheap, and correctness over a one-time cost.
        if !computing { UserDefaults.standard.set(true, forKey: Self.effortRescoreFlagKey) }
    }

    /// Compute on-device scores for each of the last `maxDays` that actually has raw HR data.
    /// Personal baselines (HRV / resting HR) are folded from the imported history, so even the first
    /// live night can be scored against your norm.
    func analyzeRecent(maxDays: Int = 21) async {
        guard !computing else { return }
        guard let store = await repo.storeHandle() else { note = "No on-device store yet."; return }
        guard let hrvCfg = Baselines.metricCfg["hrv"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let respCfg = Baselines.metricCfg["resp"],
              let skinCfg = Baselines.metricCfg["skin_temp"] else { return }

        computing = true
        defer { computing = false }

        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex,
                             stepTicksPerStep: profile.stepTicksPerStep)

        let maxHR = profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride) : nil
        let now = Int(Date().timeIntervalSince1970)
        // Device wall-clock offset (seconds east of UTC) for the sleep detector's daytime
        // false-sleep guard (#90): the stager places each window's center on the LOCAL clock
        // so only genuinely-daytime windows face the stricter nap bar. (Computed once; a DST
        // boundary inside the window is a negligible edge case for an hour-of-day band.)
        let tzOffset = TimeZone.current.secondsFromGMT()

        // ── Pass 1: analyse each offloaded night against the IMPORTED-ONLY baseline. For a BLE-only
        // user the imported daily rows are empty, so the HRV baseline isn't usable yet and recovery is
        // null here — but each night's avgHrv/restingHr are computed baseline-INDEPENDENTLY, so we
        // harvest them to SEED the baseline and re-score in pass 2. foldHistory winsorizes outliers.
        //
        // Read the imported rows DIRECTLY (deviceId is the imported id; computed rows live under the
        // sibling `-noop` id) over the full history, sorted chronologically — NOT `repo.days`, which is
        // the merged published cache (it pre-loads prior computed `-noop` rows and back-fills nil
        // imported HRV/RHR/resp fields from computed values). Using the merge contaminated this very
        // "imported-only" baseline with computed values and made the fold window depend on whichever
        // refresh last ran (4000 vs 120 days). This mirrors the Android port's `days(importedDeviceId)`.
        let hist = ((try? await store.dailyMetrics(deviceId: deviceId, from: "0000-01-01", to: "9999-12-31")) ?? [])
            .sorted { $0.day < $1.day }
        let hrvBase1 = Baselines.foldHistory(hist.map { $0.avgHrv }, cfg: hrvCfg)
        let rhrBase1 = Baselines.foldHistory(hist.map { $0.restingHr.map(Double.init) }, cfg: rhrCfg)
        let baselines1 = AnalyticsEngine.ProfileBaselines(hrv: hrvBase1, restingHR: rhrBase1)

        // Keep each night's small result (daily metrics + sessions), NOT the raw streams — every field
        // except recovery is baseline-independent, so pass 2 only re-scores the cheap recovery
        // composite. The hr/rr/resp/gravity arrays go out of scope each iteration (memory stays bounded).
        var scoredNights: [(daily: DailyMetric, strain: Double?, cachedSleep: [CachedSleepSession],
                            workouts: [ExerciseSession], nightlySkin: Double?)] = []
        // Nightly values harvested in pass 1, keyed by day, to seed the pass-2 baseline.
        var nightlyHrvByDay: [String: Double?] = [:]
        var nightlyRhrByDay: [String: Double?] = [:]
        // On-device RSA respiration + wear-gated skin-temp means (baseline-independent), harvested to
        // seed resp/skin-temp baselines the same way avgHrv seeds the HRV baseline.
        var nightlyRespByDay: [String: Double?] = [:]
        var nightlySkinByDay: [String: Double?] = [:]

        // Device-registry snapshot for per-day owner resolution (invariant I2 — a day's scores come from
        // exactly ONE source). Read once before the loop: the paired-device list + the active id are
        // stable for the run. With only the seeded 'my-whoop' row paired (the default and every
        // single-WHOOP install) the active strap is `deviceId`, so `resolveDayOwner` below returns
        // `deviceId` for every day and the per-day reads are byte-identical to the pre-I2 behaviour.
        let registry = DeviceRegistryStore(dbQueue: store.registryQueue)
        let regDevices = (try? registry.all()) ?? []
        let regActiveId = (try? registry.activeDeviceId()) ?? deviceId

        // Floor `now` to LOCAL midnight (#277) so each `dayStart` lands on a local-day boundary and the
        // day keys are LOCAL calendar days, consistent with the dashboard's local "today" lookup. A
        // west-of-UTC user's evening crosses midnight UTC; bucketing by UTC put it in the next UTC day,
        // which the local read never found (Toronto/UTC-4 report).
        let nowLocalMidnight = Self.midnightLocal(now, offsetSec: tzOffset)
        for offset in 0..<maxDays {
            let dayStart = nowLocalMidnight - offset * 86_400
            let day = AnalyticsEngine.dayString(dayStart, offsetSec: tzOffset)
            // Read a generous window around the night that ends on `day`; the stager finds the span.
            let from = dayStart - 30 * 3_600
            let to = dayStart + 12 * 3_600

            // I2: pick the single device that owns this day, and read ITS streams below. With one device
            // this resolves to `deviceId` (active strap, has data → priority 0), so nothing changes; with
            // multiple sources the day is scored from exactly one (active strap > other live straps >
            // imports, or a locked override). Falls back to `deviceId` if the registry is unreadable.
            let owner = await resolveDayOwner(day: day, from: from, to: to, store: store,
                                              devices: regDevices, activeId: regActiveId,
                                              registry: registry)

            let hr = (try? await store.hrSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
            guard hr.count >= 200 else { continue }   // need real raw data, not a stray sample
            let rr = (try? await store.rrIntervals(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
            let resp = (try? await store.respSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
            let grav = (try? await store.gravitySamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
            let steps = (try? await store.stepSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
            let skin = (try? await store.skinTempSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []

            // Calendar-day window for the ADDITIVE daily totals (steps + calories). The night window
            // above is anchored to the current time-of-day and ends at dayStart+12h, so for a PAST
            // day whose late hours sit after that bound those hours are never read and the totals
            // undercount. Read exactly [localMidnight(day), localMidnight(day)+86400) and hand it to
            // analyzeDay's dayHr/daySteps, which use it ONLY for those totals. `dayStart` is already a
            // LOCAL midnight; midnightLocal is idempotent on it (the store range is inclusive, so end
            // at -1 s). (#277 — local-day bucketing.)
            let dayMid = Self.midnightLocal(dayStart, offsetSec: tzOffset)
            let dayEnd = dayMid + 86_400 - 1
            // Same `owner` as the night window above (I2): the additive day totals must come from the
            // one device that owns the day, never a mix.
            let dayHr = (try? await store.hrSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
            let daySteps = (try? await store.stepSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []

            let res = await Task.detached(priority: .utility) {
                AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: resp, gravity: grav,
                                           steps: steps, dayHr: dayHr, daySteps: daySteps,
                                           skinTemp: skin,
                                           profile: up, baselines: baselines1, maxHROverride: maxHR,
                                           tzOffsetSeconds: tzOffset)
            }.value
            nightlyHrvByDay[res.daily.day] = res.daily.avgHrv
            nightlyRhrByDay[res.daily.day] = res.daily.restingHr.map(Double.init)
            nightlyRespByDay[res.daily.day] = res.daily.respRateBpm
            nightlySkinByDay[res.daily.day] = res.nightlySkinTempC
            scoredNights.append((daily: res.daily, strain: res.strain, cachedSleep: res.cachedSleep,
                                 workouts: res.workouts, nightlySkin: res.nightlySkinTempC))
            await Task.yield()
        }

        // ── Seed the baseline from the UNION of imported nightly history + the values just computed.
        // THIS is the BLE-only recovery fix: the "-noop" nightly avgHrv/restingHr finally feed the
        // baseline so a strap-only user crosses Baselines.minNightsSeed and recovery lights up.
        // IMPORTED values win per day: write them first, then fill ONLY days the import doesn't cover
        // (Swift has no putIfAbsent — `dict[day] == nil` is true only when the KEY is absent, so a day
        // imported with a nil avgHrv stays imported, not overwritten by the computed value).
        var histHrvByDay: [String: Double?] = [:]
        var histRhrByDay: [String: Double?] = [:]
        var histRespByDay: [String: Double?] = [:]
        for d in hist {
            histHrvByDay[d.day] = d.avgHrv
            histRhrByDay[d.day] = d.restingHr.map(Double.init)
            histRespByDay[d.day] = d.respRateBpm
        }
        for (day, v) in nightlyHrvByDay where histHrvByDay[day] == nil { histHrvByDay[day] = v }
        for (day, v) in nightlyRhrByDay where histRhrByDay[day] == nil { histRhrByDay[day] = v }
        for (day, v) in nightlyRespByDay where histRespByDay[day] == nil { histRespByDay[day] = v }
        let hrvSeq = histHrvByDay.keys.sorted().map { histHrvByDay[$0]! }   // chronological [Double?]
        let rhrSeq = histRhrByDay.keys.sorted().map { histRhrByDay[$0]! }
        let respSeq = histRespByDay.keys.sorted().map { histRespByDay[$0]! }
        // Skin-temp baseline is on-device-only (imported rows carry skinTempDevC, not the raw mean),
        // so fold purely over the pass-1 nightly means in chronological order.
        let skinSeq = nightlySkinByDay.keys.sorted().map { nightlySkinByDay[$0]! }
        // Resp baseline gated on `usable`: RecoveryScorer includes the resp term whenever a
        // baseline object is present — a CALIBRATING (<4-night) baseline would let one noisy
        // RSA night move recovery (mirrors the skin-temp use-site gate; honest cold-start).
        let respFold = Baselines.foldHistory(respSeq, cfg: respCfg)
        // Skin-temp gated the same way for consistency: its only use-site re-checks `.usable`
        // (AnalyticsEngine's skinTempDevC guard) so this is belt-and-suspenders, but it stops a
        // future use-site from trusting a CALIBRATING baseline. (PR #97 review.)
        let skinFold = Baselines.foldHistory(skinSeq, cfg: skinCfg)
        let baselines2 = AnalyticsEngine.ProfileBaselines(
            hrv: Baselines.foldHistory(hrvSeq, cfg: hrvCfg),
            restingHR: Baselines.foldHistory(rhrSeq, cfg: rhrCfg),
            resp: respFold.usable ? respFold : nil,
            skinTemp: skinFold.usable ? skinFold : nil)

        // Real (non-detected) workouts in the scored window, used to de-duplicate detected bouts so a
        // user who BOTH has real sessions AND wears the strap doesn't see the same session twice (the
        // per-day merge precedence does not cover the workout table). This covers BOTH directions of
        // the cross-source duplicate (#107): the strap source carries imported WHOOP rows AND manual /
        // re-labelled rows (both written under `deviceId`), and apple-health carries Health imports —
        // a detected bout overlapping ANY of them is skipped below. Port of the Android dedup block.
        let computedId = deviceId + "-noop"
        let windowStart = now - maxDays * 86_400 - 30 * 3_600
        var realWorkouts = (try? await store.workouts(deviceId: deviceId, from: windowStart,
                                                       to: now, limit: 100_000)) ?? []
        realWorkouts += (try? await store.workouts(deviceId: "apple-health", from: windowStart,
                                                    to: now, limit: 100_000)) ?? []

        // ── Pass 2: re-score ONLY recovery against the now-seeded baseline (cheap, baseline-dependent);
        // every other field was computed once in pass 1. Recovery stays nil until the HRV baseline is
        // usable (≥ minNightsSeed valid nights) — honest cold-start, via RecoveryScorer's usable gate.
        var out: [Computed] = []
        var dailies: [DailyMetric] = []
        var cachedSleep: [CachedSleepSession] = []
        var workoutRows: [WorkoutRow] = []
        // Rest composite (0–100) per computed night, persisted as the `sleep_performance` metric
        // series so the dashboard's Rest score reflects the new composite, not raw efficiency.
        var restPoints: [MetricPoint] = []
        // User-corrected sleep windows override the detected sleep when scoring a day's sleep aggregates,
        // so Rest + recovery honor the edit — not just the Sleep tab's session view. An edited block
        // substitutes its detected twin (matched by the stable detected startTs) before totals recompute.
        // Scope (#318): this only covers the COMPUTED ("-noop") source — the days noop scores itself. An
        // edit to an IMPORTED (WHOOP-export) night updates the displayed session, but its dashboard
        // recovery/performance come verbatim from the export and are NOT recomputed here (we don't
        // reproduce WHOOP's cloud scoring). That's an accepted limitation, documented on the PR.
        let editedRows = ((try? await store.sleepSessions(deviceId: computedId, from: windowStart,
                                                          to: now, limit: 100_000)) ?? [])
            .filter { $0.userEdited }
        let editsByStart = Dictionary(editedRows.map { ($0.startTs, $0) }, uniquingKeysWith: { a, _ in a })
        for night in scoredNights {
            let daily = sleepEditedDaily(night.daily, detected: night.cachedSleep, editsByStart: editsByStart)
            let recovery = recomputeRecovery(daily, baselines2)
            let skinDev = recomputeSkinTempDev(night.nightlySkin, baselines2.skinTemp)
            out.append(Computed(day: daily.day, recovery: recovery, strain: night.strain,
                                sleepMin: daily.totalSleepMin, hrv: daily.avgHrv,
                                rhr: daily.restingHr))
            dailies.append(daily.with(recovery: recovery, skinTempDevC: skinDev))
            if let rest = AnalyticsEngine.Rest.composite(daily: daily) {
                restPoints.append(MetricPoint(day: daily.day, key: "sleep_performance", value: rest))
            }
            cachedSleep.append(contentsOf: night.cachedSleep)
            // Persist the detected workouts the pipeline already computes (previously discarded).
            // Skip any bout overlapping a real imported workout so import+wear users don't
            // double-count. sport = "detected"; energyKcal is the APPROXIMATE Keytel/BMR total.
            for s in night.workouts {
                if realWorkouts.contains(where: { s.start < $0.endTs && $0.startTs < s.end }) { continue }
                workoutRows.append(WorkoutRow(startTs: s.start, endTs: s.end,
                                              sport: "detected", source: computedId,
                                              durationS: s.durationS, energyKcal: s.caloriesKcal,
                                              avgHr: Int(s.avgHR), maxHr: s.peakHR,
                                              strain: s.strain, distanceM: nil,
                                              zonesJSON: nil, notes: nil))
            }
        }

        // #277 migration: the loop now keys days by the LOCAL calendar day. A prior run (before this
        // fix) wrote the SAME period under UTC-day keys, so without a cleanup an off-by-one UTC row and
        // the new local row would coexist as duplicate days. Delete the COMPUTED ("-noop") daily rows
        // across the recompute window [oldest enumerated local day, newest] BEFORE re-upserting, then
        // re-insert the local-keyed rows. Scoped to the computed source only — imported "my-whoop" rows
        // are never touched (a BLE-only WHOOP 4.0 user has no import fallback). Rows older than the
        // window keep their old keys (cosmetic off-by-one, acceptable). yyyy-MM-dd sorts
        // chronologically, so the string range IS a date range.
        let oldestDay = AnalyticsEngine.dayString(nowLocalMidnight - (maxDays - 1) * 86_400,
                                                  offsetSec: tzOffset)
        let newestDay = AnalyticsEngine.dayString(nowLocalMidnight, offsetSec: tzOffset)
        _ = try? await store.deleteDailyMetrics(deviceId: computedId, from: oldestDay, to: newestDay)

        // Persist the computed scores under a dedicated "-noop" source so the WHOLE dashboard
        // (Today / Recovery / Strain / Sleep / Trends), not just this screen, reads them. The
        // Repository merges these UNDER any imported "my-whoop" rows, so a real WHOOP import
        // always wins; this only fills the days the strap collected but no import covered.
        if !dailies.isEmpty { _ = try? await store.upsertDailyMetrics(dailies, deviceId: computedId) }
        if !restPoints.isEmpty { _ = try? await store.upsertMetricSeries(restPoints, deviceId: computedId) }

        // ── Fitness Age (Phase 2) — weekly, keyed to the week's Saturday ────────────────────────────
        // Roll the last 7 computed days into the Nes/HUNT inputs and upsert a weekly Fitness Age (+ an
        // optional VO₂max when a waist is set) under the same "-noop" source. Idempotent on the Saturday
        // key, so the number refines through the week and finalises on Saturday. Engine = FitnessAgeEngine
        // (StrandAnalytics), fully unit-tested; the body term cancels so the headline needs no body metric.
        let fa7 = dailies.sorted { $0.day < $1.day }.suffix(7)
        let faRHRs = fa7.compactMap { $0.restingHr }.map(Double.init)
        let faActiveStrains = fa7.compactMap { $0.strain }.filter { $0 >= 30 }
        let faMeanActiveStrain = faActiveStrains.isEmpty ? 0
            : faActiveStrains.reduce(0, +) / Double(faActiveStrains.count)
        let faWaist: Double? = profile.waistCm > 0 ? profile.waistCm : nil
        let faReady = FitnessAgeEngine.assessReadiness(
            hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty,
            rhrDays: faRHRs.count, activityDays: fa7.compactMap { $0.strain }.count,
            hasHeightWeight: profile.heightCm > 0 && profile.weightKg > 0, hasWaist: faWaist != nil)
        if faReady.canCompute,
           let faRes = FitnessAgeEngine.compute(
                age: Double(profile.age), sex: profile.sex,
                restingHR: IntelligenceEngine.medianOf(faRHRs),
                paIndex: FitnessAgeEngine.physicalActivityIndexFromStrain(
                    activeDaysPerWeek: faActiveStrains.count, meanActiveStrain: faMeanActiveStrain),
                waistCm: faWaist) {
            let satKey = IntelligenceEngine.saturdayKey(onOrBefore: newestDay)
            var faPts = [MetricPoint(day: satKey, key: "fitness_age", value: faRes.fitnessAge)]
            if let v = faRes.vo2max { faPts.append(MetricPoint(day: satKey, key: "vo2max_est", value: v)) }
            _ = try? await store.upsertMetricSeries(faPts, deviceId: computedId)
        }

        // ── Vitality / Body Age (Phase 7) — weekly, keyed to the week's Saturday ────────────────────
        // Roll the last 7 days' wearable signals into the mortality-hazard model and upsert a weekly
        // Vitality (0–100) + Body Age. VitalityEngine gates on ≥3 inputs, so a sparse week writes nothing.
        // (VO₂max is omitted here — fitness is already its own Fitness Age headline; Vitality leans on
        // resting HR, sleep duration + regularity, HRV-vs-age-norm, and steps.)
        let vNights = fa7.compactMap { $0.totalSleepMin }.map { Double($0) / 60.0 }.filter { $0 > 0 }
        let vHRVs = fa7.compactMap { $0.avgHrv }
        let vSteps = fa7.compactMap { $0.steps }.map(Double.init)
        let vInputs = VitalityEngine.Inputs(
            chronoAge: Double(profile.age),
            restingHR: faRHRs.isEmpty ? nil : IntelligenceEngine.medianOf(faRHRs),
            sleepHours: vNights.isEmpty ? nil : vNights.reduce(0, +) / Double(vNights.count),
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: vNights),
            rmssd: vHRVs.isEmpty ? nil : IntelligenceEngine.medianOf(vHRVs),
            rmssdNorm: VitalityEngine.rmssdNorm(forAge: Double(profile.age)),
            steps: vSteps.isEmpty ? nil : vSteps.reduce(0, +) / Double(vSteps.count))
        if let vRes = VitalityEngine.compute(vInputs) {
            let satKey = IntelligenceEngine.saturdayKey(onOrBefore: newestDay)
            _ = try? await store.upsertMetricSeries([
                MetricPoint(day: satKey, key: "vitality", value: vRes.vitality),
                MetricPoint(day: satKey, key: "body_age", value: vRes.bodyAge),
            ], deviceId: computedId)
        }
        // Drop any freshly-detected session that overlaps a night the user has already hand-corrected.
        // A detected onset can drift second-to-second as more raw data arrives, so without this the
        // re-detected night would upsert as a SECOND row beside the edited one (different startTs ⇒ no
        // ON CONFLICT match), and mergeDay would DOUBLE-COUNT both into an inflated time-in-bed. The
        // edited row is already stored (preserved by the upsert guard), so we simply don't re-insert its
        // detected twin. Sleep has no delete-reinsert pass (unlike dailyMetric/workout), so this is the
        // idempotency guard for the edited case. (#318)
        let editedWindows = editedRows.map { (start: $0.effectiveStartTs, end: $0.endTs) }
        let cachedSleepKept = cachedSleep.filter { s in
            !editedWindows.contains { s.startTs < $0.end && $0.start < s.endTs }   // time-overlap test
        }
        if !cachedSleepKept.isEmpty { _ = try? await store.upsertSleepSessions(cachedSleepKept, deviceId: computedId) }
        // Make re-detection idempotent across runs: clear the prior computed detected workouts in the
        // scored window (a bout's startTs can drift as more HR arrives, which would otherwise orphan
        // stale rows under the (deviceId,startTs,sport) key), then re-insert.
        _ = try? await store.deleteWorkouts(deviceId: computedId, sport: "detected",
                                            from: windowStart, to: now)
        if !workoutRows.isEmpty { _ = try? await store.upsertWorkouts(workoutRows, deviceId: computedId) }

        // #137: a manually-started workout is scored from sparse live HR at save time — near-zero
        // calories/strain on a 5/MG. Now that offloaded HR may cover the window, re-score the
        // under-sampled ones from that denser data.
        await rescoreManualWorkouts(store: store, profile: up)

        results = out
        note = out.isEmpty
            ? "No scored nights yet. Wear the strap with NOOP connected overnight and the engine will score your charge, effort and rest itself, no WHOOP cloud required."
            : nil

        // Reload the dashboard caches so the freshly computed scores show up immediately.
        if !dailies.isEmpty { await repo.refresh() }
    }

    /// Resolve the SINGLE device that owns `day` (invariant I2), so the day is scored from exactly one
    /// source — never a mix. Builds one `DayOwnerResolver.Candidate` per non-archived device with a
    /// priority (0 = the active strap, 1 = other live straps, 2 = imports; lower wins) and a CHEAP
    /// per-day presence flag (one `LIMIT 1` HR read per device), then applies any locked override from
    /// the dayOwnership table. Returns `deviceId` when the registry yields no owner (no candidate has
    /// data, or it's empty/unreadable) so the legacy single-source path is preserved.
    ///
    /// Single-device install: the only paired row is the seeded active 'my-whoop' (== `deviceId`). Its
    /// candidate is priority 0 with `hasData == true` for any day the strap collected HR, so the
    /// resolver returns `deviceId` and the caller's reads are byte-identical to the pre-I2 code. The
    /// presence check is the same `LIMIT 1` over the same window the caller already reads.
    private func resolveDayOwner(day: String, from: Int, to: Int, store: WhoopStore,
                                 devices: [PairedDevice], activeId: String,
                                 registry: DeviceRegistryStore) async -> String {
        // A locked override wins outright and skips the presence checks entirely.
        if let locked = (try? registry.dayOwner(day))?.deviceId {
            return locked
        }
        // No registry rows (shouldn't happen — v15 seeds one — but be safe): keep the legacy id.
        guard !devices.isEmpty else { return deviceId }

        var candidates: [DayOwnerResolver.Candidate] = []
        for d in devices where d.status != .archived {
            let isImport = d.sourceKind == .cloudImport || d.sourceKind == .fileImport
            let priority = d.id == activeId ? 0 : (isImport ? 2 : 1)
            // Cheap presence check: a single HR row for this device in the night window is enough to
            // mark it a candidate. (LIMIT 1 — not the full pull the caller does once an owner is chosen.)
            let hasData = !((try? await store.hrSamples(deviceId: d.id, from: from, to: to, limit: 1)) ?? []).isEmpty
            candidates.append(DayOwnerResolver.Candidate(deviceId: d.id, priority: priority, hasData: hasData))
        }
        return DayOwnerResolver.resolve(day: day, lockedOwner: nil, candidates: candidates) ?? deviceId
    }

    /// #137: re-score under-sampled manual workouts. A `manual` workout is scored from the live HR
    /// captured during the session; on a 5/MG that stream is sparse, so calories/strain land near zero.
    /// The strap banks its own HR and offloads it on sync — once that denser HR covers the workout's
    /// window, recompute from it. Conservative + idempotent: only `manual` rows that look under-scored
    /// (negligible calories), and only when the recompute is a genuine improvement — so a well-scored
    /// 4.0 workout is never touched and a still-sparse window is a no-op.
    private func rescoreManualWorkouts(store: WhoopStore, profile up: UserProfile) async {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - 14 * 86_400
        guard let rows = try? await store.workouts(deviceId: deviceId, from: since, to: now, limit: 200)
        else { return }
        let hrMax = Double(profile.hrMax)
        var updated: [WorkoutRow] = []
        for row in rows where row.source == "manual"
            && ManualWorkoutRescore.looksUnderScored(currentKcal: row.energyKcal) {
            guard let samples = try? await store.hrSamples(deviceId: deviceId, from: row.startTs,
                                                           to: row.endTs, limit: 20_000),
                  let s = ManualWorkoutRescore.scored(windowSamples: samples, profile: up, hrMax: hrMax),
                  ManualWorkoutRescore.improves(s, over: row.energyKcal)
            else { continue }
            updated.append(WorkoutRow(
                startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
                durationS: row.durationS, energyKcal: s.kcal, avgHr: s.avgHr, maxHr: s.maxHr,
                strain: s.strain, distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes))
        }
        if !updated.isEmpty { _ = try? await store.upsertWorkouts(updated, deviceId: deviceId) }
    }

    /// Re-score ONLY the recovery composite for a day against a (re-seeded) baseline. Every other field
    /// in `daily` is baseline-independent and already final from pass 1. Returns nil until the HRV
    /// baseline is usable (RecoveryScorer gates on `hrvBaseline.usable`, i.e. ≥ minNightsSeed valid
    /// nights) — so the honest null-until-4-nights cold-start is free. Mirrors AnalyticsEngine's own
    /// recovery call + Android IntelligenceEngine.recomputeRecovery. (#78)
    private func recomputeRecovery(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines) -> Double? {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else { return nil }
        // Charge enrichment: feed the Rest COMPOSITE (÷100) as the sleep-quality term instead of raw
        // efficiency, and fold in the night's skin-temp deviation. Both come from the persisted daily
        // fields (the raw streams are gone in pass 2). (Charge/Effort/Rest scoring redesign.)
        let restQuality = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency
        return RecoveryScorer.recovery(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                       hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                       respBaseline: baselines.resp, sleepPerf: restQuality,
                                       skinTempDev: daily.skinTempDevC)
    }

    /// Override a day's detected sleep aggregates with the user's hand-corrected window when one of the
    /// night's blocks was edited. Substitutes each edited block (matched by its stable startTs) for its
    /// detected twin and recomputes totalSleep / efficiency / stage minutes from the reshaped stages, so
    /// the Rest composite and recovery score the corrected sleep — not the auto-detected window. No edit
    /// touching the night → the detected daily is returned unchanged. (#318)
    private func sleepEditedDaily(_ daily: DailyMetric, detected: [CachedSleepSession],
                                 editsByStart: [Int: CachedSleepSession]) -> DailyMetric {
        guard !editsByStart.isEmpty else { return daily }
        let detectedTuples = detected.map { (startTs: $0.startTs, stagesJSON: $0.stagesJSON) }
        let editedStages = editsByStart.mapValues { $0.stagesJSON }
        guard let r = SleepStageTotals.dailyAggregateHonoringEdits(detected: detectedTuples,
                                                                   edited: editedStages),
              r.editApplied else { return daily }
        let agg = r.sleep
        return daily.with(totalSleepMin: agg.totalSleepMin, efficiency: agg.efficiency,
                          deepMin: agg.deepMin, remMin: agg.remMin, lightMin: agg.lightMin)
    }

    /// Re-derive the skin-temperature deviation (°C) for a night against the freshly-seeded personal
    /// baseline, mirroring the avgHrv→recovery re-score. Nil when the night had no wear-gated mean or
    /// the skin-temp baseline isn't usable yet (< minNightsSeed) — honest cold-start. Rounded to 2 dp
    /// to match the imported/demo precision. APPROXIMATE.
    private func recomputeSkinTempDev(_ nightly: Double?, _ base: BaselineState?) -> Double? {
        guard let v = nightly, let b = base, b.usable else { return nil }
        return (Baselines.deviation(v, state: b).delta * 100.0).rounded() / 100.0
    }

    /// Floor a unix-seconds timestamp to 00:00:00 of its UTC calendar day. Mirrors the Android
    /// IntelligenceEngine.midnightUtc; the floorMod form is correct for any sign.
    nonisolated static func midnightUtc(_ ts: Int) -> Int { ts - floorMod(ts, 86_400) }

    /// Floor a unix-seconds timestamp to 00:00:00 of its LOCAL calendar day (#277). `offsetSec` is
    /// seconds EAST of UTC. Shift into local time, floor to the local day, shift back:
    /// `ts - floorMod(ts + offsetSec, 86400)`. floorMod keeps the floor correct for negative offsets
    /// and negative timestamps. `offsetSec == 0` reduces exactly to `midnightUtc`. Mirrors the
    /// Android IntelligenceEngine.midnightLocal byte-for-byte.
    nonisolated static func midnightLocal(_ ts: Int, offsetSec: Int) -> Int {
        ts - floorMod(ts + offsetSec, 86_400)
    }

    /// Euclidean modulo (result has the sign of the divisor) — matches Kotlin/Java Math.floorMod, so
    /// the LOCAL-midnight floor is identical across platforms for any sign of ts/offset. Swift's `%`
    /// is a remainder (sign of the dividend), which would mis-floor negative inputs.
    nonisolated private static func floorMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
    }
}

private extension DailyMetric {
    /// Rebuild the immutable DailyMetric with a substituted recovery + skin-temp deviation
    /// (the struct has no `copy()`). (#78)
    func with(recovery r: Double?, skinTempDevC sd: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: r, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: sd, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst)
    }

    /// Rebuild with substituted sleep-derived fields (a user-corrected wake window), leaving every
    /// non-sleep field untouched. Used by `sleepEditedDaily` so Rest/recovery score the edited sleep. (#318)
    func with(totalSleepMin tsm: Double?, efficiency eff: Double?,
              deepMin dm: Double?, remMin rm: Double?, lightMin lm: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: tsm, efficiency: eff, deepMin: dm, remMin: rm, lightMin: lm,
                    disturbances: disturbances, restingHr: restingHr, avgHrv: avgHrv, recovery: recovery,
                    strain: strain, exerciseCount: exerciseCount, spo2Pct: spo2Pct,
                    skinTempDevC: skinTempDevC, respRateBpm: respRateBpm, steps: steps,
                    activeKcalEst: activeKcalEst)
    }
}
