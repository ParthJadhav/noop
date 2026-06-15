package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/*
 * IntelligenceEngine.kt — on-device "intelligence": computes recovery / day-strain /
 * sleep from the raw strap streams using the same model shape WHOOP uses (HRV vs
 * personal baseline ~60%, resting HR ~20%, sleep ~15%, respiration ~5%; strain 0–21
 * from cardiovascular load).
 *
 * Faithful Kotlin port of Strand/Data/IntelligenceEngine.swift (verified on macOS).
 * Same windows, same thresholds, same persistence model:
 *   - For each recent day with >= MIN_HR_SAMPLES (200) HR samples, read a generous
 *     window of raw streams from the imported source ("my-whoop"), run
 *     AnalyticsEngine.analyzeDay against baselines folded from repo.days, and PERSIST
 *     the DailyMetric + sleep sessions under "<deviceId>-noop" (the computed source).
 *   - The repository merges these UNDER any imported "my-whoop" rows, so a real WHOOP
 *     import always wins; this only fills the days the strap collected but no import
 *     covered.
 *
 * This is what makes NOOP independent of WHOOP's cloud — for any day the strap
 * collected raw data with NOOP connected, NOOP scores it itself rather than relying on
 * the values WHOOP computed in the imported CSV.
 *
 * Stateless object (no ObservableObject equivalent here): the Compose layer observes
 * the repository's reactive day flow, so this engine just computes + persists, then the
 * caller (AppViewModel) lets the flow refresh the UI. All `ts` are unix SECONDS (Long).
 */
object IntelligenceEngine {

    /**
     * Per-day owner resolution source (invariant I2 — a day's scores come from exactly ONE device).
     * Pure abstraction so [analyzeRecent] resolves the owning device without taking an Android Context
     * or a Room dependency (mirrors how the engine already stays pure-JVM testable). A null source
     * (the default) preserves the legacy single-source path BYTE-FOR-BYTE: every day reads from
     * [importedDeviceId]. A DeviceRegistry-backed implementation lives in the app layer and is passed
     * in by the UI scoring pass. Mirrors the Swift IntelligenceEngine.resolveDayOwner read-through (1B-4).
     */
    interface DayOwnerSource {
        /** Non-archived paired devices, each as a [DayOwnerResolver.Candidate] WITHOUT its hasData flag
         *  resolved yet (priority only: 0 = active strap, 1 = other live straps, 2 = imports). */
        suspend fun candidatePriorities(): List<Pair<String, Int>>

        /** A locked owner override for [day] from the dayOwnership table, or null. Wins outright. */
        suspend fun lockedOwner(day: String): String?
    }

    /** Minimum HR samples in a day's window before it is worth scoring. */
    const val MIN_HR_SAMPLES: Int = 200

    /** Read cap per stream read — matches the Swift 200_000 bound. */
    const val STREAM_LIMIT: Int = 200_000

    private const val SECONDS_PER_DAY: Long = 86_400L

    /** Summary of one scored day (for logging / a future on-device intelligence screen). */
    data class Computed(
        val day: String,
        val recovery: Double?,
        val strain: Double?,
        val sleepMin: Double?,
        val hrv: Double?,
        val rhr: Int?,
    )

    /**
     * Compute on-device scores for each of the last [maxDays] that actually has raw HR
     * data, persisting them under the computed "<importedDeviceId>-noop" source.
     *
     * Personal baselines (HRV / resting HR) are folded from the imported nightly history
     * (via [WhoopRepository.days]), so even the first live night can be scored against
     * the user's norm.
     *
     * @param repo the local store.
     * @param profile body profile (age/sex/weight/height + HRmax override) for HRmax,
     *   zones, calories. Defaults to a neutral [UserProfile] when the caller has none.
     * @param maxDays number of trailing days to consider (default 21).
     * @param importedDeviceId the source id the raw strap data is stored under
     *   ("my-whoop"). Computed scores are written under "<importedDeviceId>-noop".
     * @param maxHROverride explicit HRmax (bpm); null → Tanaka from profile.age.
     * @param nowSeconds wall-clock now (unix seconds); injectable for tests/determinism.
     * @return the per-day [Computed] summaries (newest first), mirroring the Swift `out`.
     */
    /**
     * Public entry: hop OFF the caller's thread before the CPU-heavy scoring. The AppViewModel 15-min
     * loop launches from viewModelScope (Dispatchers.Main), so without this hop the whole pass —
     * SleepStager / StrainScorer over up to 21 nights of 1 Hz data — ran on the MAIN THREAD and
     * ANR-killed the app once a few nights had accumulated. Dispatchers.Default is the CPU pool; Room's
     * suspend DAO calls are main-safe under any dispatcher. (#125)
     */
    suspend fun analyzeRecent(
        repo: WhoopRepository,
        profile: UserProfile = UserProfile(),
        maxDays: Int = 21,
        importedDeviceId: String = "my-whoop",
        maxHROverride: Double? = null,
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
        ownerSource: DayOwnerSource? = null,
    ): List<Computed> = withContext(Dispatchers.Default) {
        analyzeRecentOnCpu(repo, profile, maxDays, importedDeviceId, maxHROverride, nowSeconds, ownerSource)
    }

    /** History span for the one-shot Effort rescore — large enough to cover any real wear history,
     *  matching the Swift `historyDays` default. */
    const val EFFORT_RESCORE_HISTORY_DAYS: Int = 4000

    /**
     * One-shot, on-upgrade FULL-history Effort rescore (#313 PART B). The Effort hero gauge + numbers
     * moved from the old 0–21 axis to NOOP's own 0–100 axis. On-device computed rows since v2.6.0 already
     * store 0–100, but rows the engine computed on an OLDER build (capped at [maxDays] per run, so deep
     * history was never revisited) may still hold 0–21 strain.
     *
     * The SAFE fix is to recompute strain FROM SOURCE for every day with raw HR — those regenerate at
     * 0–100 with NO double-rescale risk — rather than a blind `strain*100/21` multiply that would
     * double-rescale the large population already on 0–100 (→ ~0–476). We do that by running the normal
     * [analyzeRecent] once with the [maxDays] cap lifted to the full history, then persist a flag (via the
     * injected [flagGet]/[flagSet]) so it runs exactly once. IMPORTED rows are never rewritten here (the
     * engine only ever writes under the "-noop" computed source) — those are handled by re-import. A day
     * already on 0–100 is recomputed from the same raw HR and lands on 0–100 again: UNCHANGED axis.
     *
     * The flag get/set are passed in so this stays a pure-JVM analytics object (no Android Context). The
     * caller (AppViewModel) wires them to [com.noop.ui.NoopPrefs]. Mirrors Swift
     * IntelligenceEngine.runEffortRescoreIfNeeded.
     */
    suspend fun runEffortRescoreIfNeeded(
        repo: WhoopRepository,
        profile: UserProfile = UserProfile(),
        importedDeviceId: String = "my-whoop",
        maxHROverride: Double? = null,
        flagGet: () -> Boolean,
        flagSet: () -> Unit,
        historyDays: Int = EFFORT_RESCORE_HISTORY_DAYS,
    ) {
        if (flagGet()) return
        analyzeRecent(
            repo = repo,
            profile = profile,
            maxDays = historyDays,
            importedDeviceId = importedDeviceId,
            maxHROverride = maxHROverride,
        )
        flagSet()
    }

    private suspend fun analyzeRecentOnCpu(
        repo: WhoopRepository,
        profile: UserProfile = UserProfile(),
        maxDays: Int = 21,
        importedDeviceId: String = "my-whoop",
        maxHROverride: Double? = null,
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
        ownerSource: DayOwnerSource? = null,
    ): List<Computed> {
        val hrvCfg = Baselines.metricCfg["hrv"] ?: return emptyList()
        val rhrCfg = Baselines.metricCfg["resting_hr"] ?: return emptyList()
        val skinCfg = Baselines.metricCfg["skin_temp"] ?: return emptyList()
        val respCfg = Baselines.metricCfg["resp"] ?: return emptyList()

        val computedId = importedDeviceId + "-noop"

        // Device wall-clock offset (seconds east of UTC) for the sleep detector's daytime
        // false-sleep guard (#90): the stager places each window's center on the LOCAL clock so
        // only genuinely-daytime windows face the stricter nap bar. getOffset(nowMillis) folds in
        // the current DST state (a DST boundary inside a single window is a negligible edge case
        // for an hour-of-day band). Computed once per run.
        val tzOffsetSeconds =
            java.util.TimeZone.getDefault().getOffset(nowSeconds * 1_000L) / 1_000L

        // Device-registry snapshot for per-day owner resolution (invariant I2 — a day's scores come from
        // exactly ONE source). Read ONCE before the loop: the paired-device list is stable for the run.
        // With only the seeded 'my-whoop' row paired (the default and every single-WHOOP install) the
        // active strap == [importedDeviceId], so [resolveDayOwner] returns [importedDeviceId] for every
        // day and the per-day reads are BYTE-IDENTICAL to the pre-I2 path. A null [ownerSource] (the
        // default, e.g. the backfill-triggered pass) skips resolution entirely. Mirrors the Swift
        // IntelligenceEngine.analyzeRecent registry snapshot + resolveDayOwner. (1B-4)
        val candidatePriorities = ownerSource?.candidatePriorities().orEmpty()

        // ── Pass 1: detect + aggregate each offloaded night, scoring against the
        // imported-only baseline. For a BLE-only user repo.days(importedDeviceId) is
        // empty, so the HRV baseline is NOT usable and res.recovery is null here — but
        // the per-night avgHrv/restingHr are computed WITHOUT any baseline dependency
        // (SleepStager + AnalyticsEngine), so we harvest them to SEED the baseline and
        // re-score in pass 2. Collected oldest-first to match foldHistory's replay order.
        // foldHistory winsorizes outliers. days() is oldest-first (Swift ascending).
        val hist = repo.days(importedDeviceId)
        val hrvBase1 = Baselines.foldHistory(hist.map { it.avgHrv }, hrvCfg)
        val rhrBase1 = Baselines.foldHistory(hist.map { it.restingHr?.toDouble() }, rhrCfg)
        val baselines1 = ProfileBaselines(hrv = hrvBase1, restingHR = rhrBase1)

        // Keep each night's small DayResult (daily metrics + detected sessions), NOT the raw
        // streams: every field except recovery is baseline-independent, so pass 2 only re-scores
        // the cheap recovery composite. The raw hr/rr/... lists are freed after each analyzeDay,
        // keeping memory bounded over a full multi-night offload history.
        val scoredNights = ArrayList<DayResult>()

        // In-memory nightly values harvested in pass 1, used to seed the pass-2 baseline.
        // Keyed by day so the union with imported history de-dupes cleanly per UTC day.
        val nightlyHrvByDay = LinkedHashMap<String, Double?>()
        val nightlyRhrByDay = LinkedHashMap<String, Double?>()
        // Wear-gated nightly skin-temp means (on-device only — imported rows carry the deviation, not
        // the raw mean, so the skin-temp baseline is seeded purely from these). (PR #85)
        val nightlySkinByDay = LinkedHashMap<String, Double?>()
        // On-device RSA respiration estimates, unioned with imported respRateBpm below to seed the
        // resp baseline the recovery composite's wResp=0.05 term scores against.
        val nightlyRespByDay = LinkedHashMap<String, Double?>()

        // Floor `now` to LOCAL midnight (#277) so each `dayStart` lands on a local-day boundary and the
        // day keys are LOCAL calendar days, consistent with the dashboard's local "today" lookup. A
        // west-of-UTC user's evening crosses midnight UTC; bucketing by UTC put it in the next UTC day,
        // which the local read never found (Toronto/UTC-4 report).
        val nowLocalMidnight = midnightLocal(nowSeconds, tzOffsetSeconds)
        for (offset in 0 until maxDays) {
            val dayStart = nowLocalMidnight - offset * SECONDS_PER_DAY
            val day = AnalyticsEngine.dayString(dayStart, tzOffsetSeconds)
            // Read a generous window around the night that ends on `day`; the stager finds
            // the span. (30 h before, 12 h after — matches the Swift window.)
            val from = dayStart - 30 * 3_600L
            val to = dayStart + 12 * 3_600L

            // I2: pick the single device that OWNS this day, and read ITS streams below. With one device
            // this resolves to [importedDeviceId] (active strap, has data → priority 0), so nothing
            // changes; with multiple sources the day is scored from exactly one (active strap > other
            // live straps > imports, or a locked override). Falls back to [importedDeviceId] when no
            // owner source is supplied or the registry yields no owner.
            val owner = resolveDayOwner(repo, ownerSource, candidatePriorities, day, from, to, importedDeviceId)

            val hr = repo.hrSamples(owner, from, to, STREAM_LIMIT)
            if (hr.size < MIN_HR_SAMPLES) continue // need real raw data, not a stray sample
            val rr = repo.rrIntervals(owner, from, to, STREAM_LIMIT)
            val resp = repo.respSamples(owner, from, to, STREAM_LIMIT)
            val grav = repo.gravitySamples(owner, from, to, STREAM_LIMIT)
            val steps = repo.stepSamples(owner, from, to, STREAM_LIMIT)
            val skin = repo.skinTempSamples(owner, from, to, STREAM_LIMIT)

            // Calendar-day window for the ADDITIVE daily totals (steps + calories). The night window
            // above is anchored to the current time-of-day and ends at dayStart+12h, so for a PAST
            // day whose late hours sit after that bound those hours are never read and the totals
            // undercount. Read exactly [localMidnight(day), localMidnight(day)+86400) and hand it to
            // analyzeDay's dayHr/daySteps, which use it ONLY for those totals. Same STREAM_LIMIT; the
            // MIN_HR_SAMPLES gate above stays on the night window so empty days are still skipped.
            // `dayStart` is already a LOCAL midnight; midnightLocal is idempotent on it (the DAO range
            // is inclusive, so end at +86400-1s; analyzeDay also filters to the day). (#277)
            val dayMidnight = midnightLocal(dayStart, tzOffsetSeconds)
            val dayEnd = dayMidnight + SECONDS_PER_DAY - 1
            // Same [owner] as the night window above (I2): the additive day totals must come from the one
            // device that owns the day, never a mix.
            val dayHr = repo.hrSamples(owner, dayMidnight, dayEnd, STREAM_LIMIT)
            val daySteps = repo.stepSamples(owner, dayMidnight, dayEnd, STREAM_LIMIT)

            val res = AnalyticsEngine.analyzeDay(
                day = day,
                hr = hr,
                rr = rr,
                resp = resp,
                gravity = grav,
                steps = steps,
                dayHr = dayHr,
                daySteps = daySteps,
                skinTemp = skin,
                profile = profile,
                baselines = baselines1,
                maxHROverride = maxHROverride,
                tzOffsetSeconds = tzOffsetSeconds,
            )

            // Harvest the baseline-independent nightly aggregates (a day with no detected
            // sleep yields null → recorded as a missing night, i.e. skip-and-hold). The raw
            // streams (hr/rr/...) go out of scope here and are freed before the next night.
            nightlyHrvByDay[day] = res.daily.avgHrv
            nightlyRhrByDay[day] = res.daily.restingHr?.toDouble()
            nightlySkinByDay[day] = res.nightlySkinTempC
            nightlyRespByDay[day] = res.daily.respRateBpm
            scoredNights.add(res)
        }

        // ── Seed the baseline from the UNION of imported nightly history + the nightly
        // values just computed. This is the recovery fix: the "-noop" nightly avgHrv/
        // restingHr that already exist (and are re-derived identically here) finally feed
        // the baseline, so a BLE-only user crosses Baselines.minNightsSeed (4 valid nights)
        // and recovery lights up. We fold over the in-memory pass-1 values rather than
        // re-reading repo.days(computedId) to avoid a read-before-persist ordering hazard.
        // Chronological (oldest-first) replay: a day present in both takes the computed value.
        val histHrvByDay = LinkedHashMap<String, Double?>()
        val histRhrByDay = LinkedHashMap<String, Double?>()
        val histRespByDay = LinkedHashMap<String, Double?>()
        for (d in hist) {
            histHrvByDay[d.day] = d.avgHrv
            histRhrByDay[d.day] = d.restingHr?.toDouble()
            histRespByDay[d.day] = d.respRateBpm
        }
        // Imported (cloud) nightly values WIN per day: the on-device estimate only fills days the
        // import doesn't cover AT ALL, so an import user's baseline is unchanged. Use a key-absence
        // check, NOT putIfAbsent: Java's putIfAbsent treats a key mapped to NULL as absent, so an
        // imported day whose avgHrv/restingHr is blank would be REPLACED by the computed estimate —
        // diverging from the Swift mirror (`histHrvByDay[day] == nil` is true only when the KEY is
        // absent), which keeps that imported day as a missing night. HRV/RHR are the dominant
        // recovery drivers (~60%/~20%), so this substitution skewed Charge vs iOS. (The author already
        // fixed this for the low-weight resp term below; HRV/RHR were missed.)
        for ((day, v) in nightlyHrvByDay) if (day !in histHrvByDay) histHrvByDay[day] = v
        for ((day, v) in nightlyRhrByDay) if (day !in histRhrByDay) histRhrByDay[day] = v
        for ((day, v) in nightlyRespByDay) if (day !in histRespByDay) histRespByDay[day] = v
        val hrvSeq = histHrvByDay.entries.sortedBy { it.key }.map { it.value }
        val rhrSeq = histRhrByDay.entries.sortedBy { it.key }.map { it.value }
        val respSeq = histRespByDay.entries.sortedBy { it.key }.map { it.value }
        val hrvBase2 = Baselines.foldHistory(hrvSeq, hrvCfg)
        val rhrBase2 = Baselines.foldHistory(rhrSeq, rhrCfg)
        // Resp baseline mixes imported (cloud) values with on-device RSA estimates — acceptable: the
        // z-score is scale-tolerant, foldHistory winsorizes, and respRateBpm already carries no source
        // flag anywhere else (the illness gate treats it the same way). Gated on `usable` because
        // RecoveryScorer includes the resp term whenever a baseline object is present — a CALIBRATING
        // (<4-night) baseline would let one noisy RSA night move recovery (mirrors the skin-temp
        // use-site gate; honest cold-start).
        val respBase2 = Baselines.foldHistory(respSeq, respCfg).takeIf { it.usable }
        // Skin-temp baseline is on-device-only (imported rows carry skinTempDevC, not the raw mean),
        // so fold purely over the pass-1 nightly means in chronological order. (PR #85)
        // Gated on `usable` for consistency with the resp baseline above AND the Swift reference
        // (IntelligenceEngine.swift:162 `skinFold.usable ? skinFold : nil`) — the use-site re-checks
        // `usable` too, so this is belt-and-suspenders, but it keeps the platforms byte-aligned.
        val skinSeq = nightlySkinByDay.entries.sortedBy { it.key }.map { it.value }
        val skinBase2 = Baselines.foldHistory(skinSeq, skinCfg).takeIf { it.usable }
        val baselines2 = ProfileBaselines(
            hrv = hrvBase2, restingHR = rhrBase2, resp = respBase2, skinTemp = skinBase2,
        )

        // Real (non-detected) workouts in the scored window, used to de-duplicate detected bouts so a
        // user who BOTH has real sessions AND wears the strap doesn't see the same session twice (the
        // per-day mergeDaily precedence does not cover the workout table). Covers BOTH directions of
        // the cross-source duplicate (#107): the strap source carries imported WHOOP rows AND manual /
        // re-labelled rows (both under [importedDeviceId]); apple-health / health-connect carry Health
        // imports — a detected bout overlapping ANY of them is skipped below.
        val windowStart = nowSeconds - maxDays.toLong() * SECONDS_PER_DAY - 30 * 3_600L
        val realWorkouts = repo.workouts(importedDeviceId, windowStart, nowSeconds) +
            repo.workouts("apple-health", windowStart, nowSeconds) +
            repo.workouts("health-connect", windowStart, nowSeconds)

        // ── Pass 2: re-score every offloaded night against the now-seeded baseline. Only the
        // recovery composite is recomputed (cheap, baseline-dependent); every other field was
        // already computed in pass 1 and is baseline-independent, so the heavy sleep / strain /
        // workout / RSA analysis runs ONCE per night. recovery stays null until the HRV
        // baseline is usable (>= minNightsSeed valid nights) — honest cold-start.
        val out = ArrayList<Computed>()
        val dailies = ArrayList<DailyMetric>()
        val sleepRows = ArrayList<SleepSession>()
        val workoutRows = ArrayList<WorkoutRow>()
        // Rest composite (0–100) per night → persisted as the sleep_performance metric series so the
        // dashboard Rest score reflects the new composite, not raw efficiency. Swift parity.
        val restRows = ArrayList<MetricSeriesRow>()

        // User-corrected sleep windows for the COMPUTED source over the recompute window. They override
        // the detected sleep when scoring a day's sleep aggregates (so Rest + recovery honor the edit,
        // not just the Sleep tab's session view) AND gate the sleepRows upsert below (so a re-detected
        // night can't re-insert over the edit). Mirrors iOS IntelligenceEngine editsByStart /
        // sleepEditedDaily / cachedSleepKept. SCOPE (#318/PR #395): COMPUTED ("-noop") source only — an
        // edit to an IMPORTED (WHOOP-export) night updates the displayed session, but its dashboard
        // recovery/performance come verbatim from the export and are NOT recomputed here. Same honest
        // scope as iOS. Keyed by the IMMUTABLE detected `startTs` (never `effectiveStartTs`), so an
        // edited block lands exactly on its detected twin.
        val editedRows = repo.sleepSessions(computedId, windowStart, nowSeconds).filter { it.userEdited }
        val editsByStart: Map<Long, String?> = editedRows.associate { it.startTs to it.stagesJSON }

        for (res in scoredNights) {
            // Substitute an edited block's (reshaped) stages for its detected twin before the daily
            // sleep aggregate feeds Rest + recovery. No edit touching this night → `daily` is unchanged.
            val daily = sleepEditedDaily(res.daily, res.sleepSessions, editsByStart)
            val recovery = recomputeRecovery(daily, baselines2)
            val skinTempDevC = recomputeSkinTempDev(res.nightlySkinTempC, baselines2.skinTemp)
            RestScorer.restFromDaily(daily)?.let { rest ->
                restRows.add(MetricSeriesRow(deviceId = computedId, day = daily.day, key = "sleep_performance", value = rest))
            }

            out.add(
                Computed(
                    day = daily.day,
                    recovery = recovery,
                    strain = daily.strain,
                    sleepMin = daily.totalSleepMin,
                    hrv = daily.avgHrv,
                    rhr = daily.restingHr,
                ),
            )
            // Stamp the computed source id + the re-scored recovery & skin-temp deviation onto the row.
            dailies.add(daily.copy(deviceId = computedId, recovery = recovery, skinTempDevC = skinTempDevC))
            // Map the rich DetectedSleep sessions → Room SleepSession cache rows.
            for (s in res.sleepSessions) {
                sleepRows.add(
                    SleepSession(
                        deviceId = computedId,
                        startTs = s.start,
                        endTs = s.end,
                        efficiency = s.efficiency,
                        restingHr = s.restingHR,
                        avgHrv = s.avgHRV,
                        stagesJSON = AnalyticsEngine.encodeStages(s.stages),
                    ),
                )
            }
            // Persist the detected workouts the pipeline already computes (previously discarded).
            // Skip any bout overlapping a real imported workout so import+wear users don't
            // double-count. sport="detected"; energyKcal is the APPROXIMATE Keytel/BMR total.
            for (s in res.workouts) {
                if (realWorkouts.any { w -> s.start < w.endTs && w.startTs < s.end }) continue
                workoutRows.add(
                    WorkoutRow(
                        deviceId = computedId,
                        startTs = s.start,
                        endTs = s.end,
                        sport = "detected",
                        source = computedId,
                        durationS = s.durationS,
                        energyKcal = s.caloriesKcal,
                        avgHr = s.avgHR.toInt(),
                        maxHr = s.peakHR,
                        strain = s.strain,
                    ),
                )
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
        val oldestDay = AnalyticsEngine.dayString(
            nowLocalMidnight - (maxDays - 1) * SECONDS_PER_DAY, tzOffsetSeconds,
        )
        val newestDay = AnalyticsEngine.dayString(nowLocalMidnight, tzOffsetSeconds)
        repo.deleteComputedDailyInRange(computedId, oldestDay, newestDay)

        // Persist the computed scores under the dedicated "-noop" source so the WHOLE
        // dashboard (Today / Recovery / Strain / Sleep / Trends) reads them. The repository
        // merges these UNDER any imported "my-whoop" rows, so a real WHOOP import always wins;
        // this only fills the days the strap collected but no import covered.
        if (dailies.isNotEmpty()) repo.upsertDailyMetrics(dailies)
        if (restRows.isNotEmpty()) repo.upsertMetricSeries(restRows)

        // ── Fitness Age (Phase 2) — weekly, keyed to the week's Saturday ──
        val fa7 = dailies.sortedBy { it.day }.takeLast(7)
        val faRHRs = fa7.mapNotNull { it.restingHr }.map { it.toDouble() }
        val faActiveStrains = fa7.mapNotNull { it.strain }.filter { it >= 30.0 }
        val faMeanActiveStrain = if (faActiveStrains.isEmpty()) 0.0 else faActiveStrains.average()
        val faWaist = if (profile.waistCm > 0) profile.waistCm else null
        val faReady = FitnessAgeEngine.assessReadiness(
            hasAge = profile.age > 0, hasSex = profile.sex.isNotEmpty(),
            rhrDays = faRHRs.size, activityDays = fa7.mapNotNull { it.strain }.size,
            hasHeightWeight = profile.heightCm > 0 && profile.weightKg > 0, hasWaist = faWaist != null)
        if (faReady.canCompute) {
            val faRes = FitnessAgeEngine.compute(
                age = profile.age, sex = profile.sex,
                restingHR = medianOfDoubles(faRHRs),
                paIndex = FitnessAgeEngine.physicalActivityIndexFromStrain(faActiveStrains.size, faMeanActiveStrain),
                waistCm = faWaist)
            if (faRes != null) {
                val satKey = saturdayKeyOnOrBefore(newestDay)
                val faPts = mutableListOf(MetricSeriesRow(deviceId = computedId, day = satKey, key = "fitness_age", value = faRes.fitnessAge))
                faRes.vo2max?.let { faPts.add(MetricSeriesRow(deviceId = computedId, day = satKey, key = "vo2max_est", value = it)) }
                repo.upsertMetricSeries(faPts)
            }
        }

        // ── Vitality / Body Age (Phase 7) — weekly, keyed to the week's Saturday ──
        // Roll the last 7 days' wearable signals into the mortality-hazard model; VitalityEngine gates on
        // ≥3 inputs. VO₂max is omitted (fitness is Fitness Age's headline); Vitality leans on resting HR,
        // sleep duration + regularity, HRV-vs-age-norm, and steps.
        val vNights = fa7.mapNotNull { it.totalSleepMin }.map { it / 60.0 }.filter { it > 0 }
        val vHRVs = fa7.mapNotNull { it.avgHrv }
        val vSteps = fa7.mapNotNull { it.steps }.map { it.toDouble() }
        val vInputs = VitalityEngine.Inputs(
            chronoAge = profile.age,
            restingHR = if (faRHRs.isEmpty()) null else medianOfDoubles(faRHRs),
            sleepHours = if (vNights.isEmpty()) null else vNights.average(),
            sleepConsistency = VitalityEngine.sleepConsistency(vNights),
            rmssd = if (vHRVs.isEmpty()) null else medianOfDoubles(vHRVs),
            rmssdNorm = VitalityEngine.rmssdNorm(profile.age),
            steps = if (vSteps.isEmpty()) null else vSteps.average())
        VitalityEngine.compute(vInputs)?.let { vRes ->
            val satKey = saturdayKeyOnOrBefore(newestDay)
            repo.upsertMetricSeries(listOf(
                MetricSeriesRow(deviceId = computedId, day = satKey, key = "vitality", value = vRes.vitality),
                MetricSeriesRow(deviceId = computedId, day = satKey, key = "body_age", value = vRes.bodyAge)))
        }
        // DURABILITY GUARD (iOS PR #395 cachedSleepKept): drop any freshly-detected session that
        // time-overlaps a night the user has already hand-corrected. A detected onset can drift
        // second-to-second as more raw data arrives, so without this the re-detected night would upsert
        // as a SECOND row beside the edited one (different startTs ⇒ no ON CONFLICT match), and the
        // mergeSleep / daily aggregate would DOUBLE-COUNT both into an inflated time-in-bed AND the edit
        // would visually revert. The edited row is already stored (it carries userEdited=1 and is never
        // re-emitted here — the engine only writes detected twins), so we simply don't re-insert its
        // detected twin. Sleep has no delete-reinsert pass (unlike dailyMetric/workout), so this IS the
        // idempotency guard for the edited case. Overlap uses the edit's EFFECTIVE window. (#318)
        val editedWindows = editedRows.map { it.effectiveStartTs to it.endTs }
        val sleepKept = sleepRows.filterNot { s ->
            editedWindows.any { (start, end) -> s.startTs < end && start < s.endTs } // time-overlap test
        }
        if (sleepKept.isNotEmpty()) repo.upsertSleepSessions(sleepKept)
        // Make re-detection idempotent across runs: clear the prior computed detected workouts
        // in the scored window (a bout's startTs can drift as more HR arrives, which would
        // otherwise orphan stale rows under the (deviceId,startTs,sport) key), then re-insert.
        repo.deleteComputedWorkouts(computedId, "detected", windowStart, nowSeconds)
        if (workoutRows.isNotEmpty()) repo.upsertWorkouts(workoutRows)

        // #137: a manually-started workout is scored from sparse live HR at save time — near-zero
        // calories/strain on a 5/MG. Now that offloaded HR may cover the window, re-score the
        // under-sampled ones from that denser data.
        rescoreManualWorkouts(repo, profile, importedDeviceId, maxHROverride, nowSeconds)

        return out
    }

    /**
     * #137: re-score under-sampled manual workouts. Conservative + idempotent: only `manual` rows that
     * look under-scored (negligible calories), and only when the recompute from the now-denser HR
     * window is a genuine improvement — so a well-scored 4.0 workout is never touched and a still-sparse
     * window is a no-op. Manual workouts + live/offloaded HR both live under [deviceId] ("my-whoop").
     */
    private suspend fun rescoreManualWorkouts(
        repo: WhoopRepository,
        profile: UserProfile,
        deviceId: String,
        maxHROverride: Double?,
        nowSeconds: Long,
    ) {
        val since = nowSeconds - 14L * 86_400L
        val rows = runCatching { repo.workouts(deviceId, since, nowSeconds) }.getOrNull() ?: return
        val hrMax = maxHROverride ?: (208.0 - 0.7 * profile.age)   // Tanaka, matching endWorkout
        val updated = ArrayList<WorkoutRow>()
        for (row in rows) {
            if (row.source != "manual") continue
            if (!ManualWorkoutRescore.looksUnderScored(row.energyKcal)) continue
            val samples = runCatching { repo.hrSamples(deviceId, row.startTs, row.endTs, 20_000) }
                .getOrNull() ?: continue
            val s = ManualWorkoutRescore.scored(samples, profile, hrMax) ?: continue
            if (!ManualWorkoutRescore.improves(s, row.energyKcal)) continue
            updated.add(row.copy(energyKcal = s.kcal, avgHr = s.avgHr, maxHr = s.maxHr, strain = s.strain))
        }
        if (updated.isNotEmpty()) repo.upsertWorkouts(updated)
    }

    /**
     * Recompute ONLY the recovery composite for an already-analyzed day against a (possibly
     * freshly-seeded) baseline. Inputs are the baseline-independent values already on [daily]
     * (avgHrv / restingHr / efficiency == sleepPerf), so pass 2 avoids re-running the expensive
     * sleep / strain / workout / RSA pipeline. Mirrors the recovery gate in
     * AnalyticsEngine.analyzeDay exactly (null on missing HRV/RHR or an unusable HRV baseline).
     */
    private fun recomputeRecovery(daily: DailyMetric, baselines: ProfileBaselines): Double? {
        val hrvVal = daily.avgHrv ?: return null
        val rhrVal = daily.restingHr ?: return null
        val hrvBase = baselines.hrv ?: return null
        // Charge enrichment: feed the Rest COMPOSITE (÷100) as the sleep-quality term instead of raw
        // efficiency, and fold in the night's skin-temp deviation (both from persisted daily fields).
        // Mirrors the Swift recomputeRecovery. (Charge/Effort/Rest scoring redesign.)
        val restQuality = RestScorer.restFromDaily(daily)?.let { it / 100.0 } ?: daily.efficiency
        return RecoveryScorer.recovery(
            hrv = hrvVal,
            rhr = rhrVal.toDouble(),
            resp = daily.respRateBpm, // term drops + renormalizes when null / no usable baseline
            hrvBaseline = hrvBase,
            rhrBaseline = baselines.restingHR,
            respBaseline = baselines.resp,
            sleepPerf = restQuality,
            skinTempDev = daily.skinTempDevC,
        )
    }

    /**
     * Override a day's detected sleep aggregates with the user's hand-corrected window when one of the
     * night's blocks was edited. Substitutes each edited block (matched by its stable detected startTs)
     * for its detected twin and recomputes totalSleep / efficiency / stage minutes from the reshaped
     * stages, so the Rest composite and recovery score the corrected sleep — not the auto-detected
     * window. No edit touching the night → the detected daily is returned unchanged. Faithful twin of
     * Swift `IntelligenceEngine.sleepEditedDaily`. (#318 / PR #395)
     */
    private fun sleepEditedDaily(
        daily: DailyMetric,
        detected: List<DetectedSleep>,
        editsByStart: Map<Long, String?>,
    ): DailyMetric {
        if (editsByStart.isEmpty()) return daily
        // Match the Swift seam: detected blocks keyed by their stable startTs + their re-encoded stages.
        val detectedTuples = detected.map { it.start to AnalyticsEngine.encodeStages(it.stages) }
        val r = SleepStageTotals.dailyAggregateHonoringEdits(detectedTuples, editsByStart) ?: return daily
        if (!r.editApplied) return daily
        val agg = r.sleep
        // Substitute ONLY the sleep-derived fields; every non-sleep field is left untouched.
        return daily.copy(
            totalSleepMin = agg.totalSleepMin,
            efficiency = agg.efficiency,
            deepMin = agg.deepMin,
            remMin = agg.remMin,
            lightMin = agg.lightMin,
        )
    }

    /**
     * Re-derive the skin-temperature deviation (°C) for a night against the freshly-seeded personal
     * baseline, mirroring the avgHrv→recovery re-score. Null when the night had no wear-gated mean or
     * the skin-temp baseline isn't usable yet (< minNightsSeed) — honest cold-start. Rounded to 2 dp
     * to match the imported/demo precision. APPROXIMATE. (PR #85)
     */
    private fun recomputeSkinTempDev(nightly: Double?, base: BaselineState?): Double? {
        val v = nightly ?: return null
        val b = base?.takeIf { it.usable } ?: return null
        // Round HALF-AWAY-FROM-ZERO to 2 dp to match Swift's Double.rounded()
        // (IntelligenceEngine.swift:291). Math.round() is half-UP and would diverge on negative
        // .5 ties (e.g. −2.5 → −2 here vs Swift's −3). (Cross-platform parity.)
        val scaled = Baselines.deviation(v, b).delta * 100.0
        val r = if (scaled >= 0) Math.floor(scaled + 0.5) else Math.ceil(scaled - 0.5)
        return r / 100.0
    }

    private fun medianOfDoubles(xs: List<Double>): Double {
        if (xs.isEmpty()) return 0.0
        val s = xs.sorted(); val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
    private fun saturdayKeyOnOrBefore(dayStr: String): String = try {
        val d = java.time.LocalDate.parse(dayStr)               // yyyy-MM-dd
        val back = (d.dayOfWeek.value + 1) % 7                  // SAT->0, SUN->1, MON->2 ... FRI->6
        d.minusDays(back.toLong()).toString()
    } catch (e: Exception) { dayStr }

    /**
     * Resolve the SINGLE device that owns [day] (invariant I2), so the day is scored from exactly one
     * source — never a mix. A locked override (dayOwnership) wins outright and skips the presence checks.
     * Otherwise builds one [DayOwnerResolver.Candidate] per device from [candidatePriorities] with a CHEAP
     * per-day presence flag (one `LIMIT 1` HR read per device over the night window), and returns the
     * lowest-priority candidate that has data. Returns [importedDeviceId] when [ownerSource] is null or
     * the resolver yields no owner — so the legacy single-source path is preserved.
     *
     * Single-device install: the only paired row is the seeded active 'my-whoop' (== [importedDeviceId]).
     * Its candidate is priority 0 with hasData==true for any day the strap collected HR, so the resolver
     * returns [importedDeviceId] and the caller's reads are byte-identical to the pre-I2 code. The presence
     * check is the same `LIMIT 1` over the same window the caller already reads. Mirrors the Swift
     * IntelligenceEngine.resolveDayOwner.
     */
    private suspend fun resolveDayOwner(
        repo: WhoopRepository,
        ownerSource: DayOwnerSource?,
        candidatePriorities: List<Pair<String, Int>>,
        day: String,
        from: Long,
        to: Long,
        importedDeviceId: String,
    ): String {
        if (ownerSource == null) return importedDeviceId
        // A locked override wins outright and skips the presence checks entirely.
        ownerSource.lockedOwner(day)?.let { return it }
        if (candidatePriorities.isEmpty()) return importedDeviceId
        val candidates = candidatePriorities.map { (id, priority) ->
            // Cheap presence check: a single HR row for this device in the night window marks it a
            // candidate. (LIMIT 1 — not the full pull the caller does once an owner is chosen.)
            val hasData = repo.hrSamples(id, from, to, 1).isNotEmpty()
            DayOwnerResolver.Candidate(deviceId = id, priority = priority, hasData = hasData)
        }
        return DayOwnerResolver.resolve(day, lockedOwner = null, candidates = candidates) ?: importedDeviceId
    }

    /**
     * Floor a unix-seconds timestamp to 00:00:00 of its UTC calendar day. AnalyticsEngine.dayString
     * uses UTC, so UTC midnight = ts - floorMod(ts, 86400). floorMod is correct for any sign.
     */
    internal fun midnightUtc(ts: Long): Long = ts - Math.floorMod(ts, SECONDS_PER_DAY)

    /**
     * Floor a unix-seconds timestamp to 00:00:00 of its LOCAL calendar day (#277). [offsetSec] is
     * seconds EAST of UTC. Shift into local time, floor to the local day, shift back:
     * `ts - floorMod(ts + offsetSec, 86400)`. Math.floorMod keeps the floor correct for negative
     * offsets and negative timestamps. [offsetSec] == 0 reduces exactly to [midnightUtc]. Mirrors the
     * Swift IntelligenceEngine.midnightLocal byte-for-byte.
     */
    internal fun midnightLocal(ts: Long, offsetSec: Long): Long =
        ts - Math.floorMod(ts + offsetSec, SECONDS_PER_DAY)
}
