package com.noop.ui

import com.noop.analytics.DayOwnerResolver
import com.noop.analytics.FusionInput
import com.noop.analytics.FusionResolver
import com.noop.analytics.FusionSource
import com.noop.data.DailyMetric
import com.noop.data.WhoopRepository

/**
 * FusionDayAdapter , the small repository adapter (v5 Wave 3) that assembles a day's [FusedRecord] for
 * [FusedRecordScreen]. It reads the per-source DailyMetric rows the repository already loads, builds
 * [FusionInput]s per metric, runs the pure [FusionResolver] for each, and packs the resolved points into
 * the screen's read-model. It deliberately does NOT refactor the core resolvedSeries waterfall , it only
 * FEEDS the new view, per the wave's robustness mandate.
 *
 * Lives in the `ui` package (which already depends on `analytics`) so the engine layer stays UI-free:
 * the [FusedRecord]/[FusedRow] read-models are the screen's, the arbitration is all in [FusionResolver] /
 * MetricArbitrationPolicy. The only I/O is the per-source daily reads through [WhoopRepository.days].
 * Wellness-only , it picks the best-sourced number and names where each came from; never judges a value.
 */
object FusionDayAdapter {

    /** The fusion metrics shown on the record, in display order, each with its label + resolver key. */
    private data class MetricSpec(val key: String, val label: String)

    private val METRICS: List<MetricSpec> = listOf(
        MetricSpec("rhr", "Resting HR"),
        MetricSpec("hrv", "HRV"),
        MetricSpec("skin_temp", "Skin temperature"),
        MetricSpec("spo2", "Blood O₂"),
        MetricSpec("steps", "Steps"),
        MetricSpec("active_kcal", "Active energy"),
        MetricSpec("sleep_total_min", "Asleep time"),
        MetricSpec("sleep_deep_min", "Deep sleep"),
        MetricSpec("sleep_rem_min", "REM sleep"),
    )

    /**
     * Each fusion source paired with the deviceId/source string(s) its daily rows are stored under. The
     * strap (WHOOP_IMPORT) + its on-device computed sibling resolve against the ACTIVE strap id from the
     * device registry, NOT the hardcoded "my-whoop" (SPINE / #814): a non-WHOOP active band stores its rows
     * under its own id, so a hardcoded read would fuse the wrong device's data.
     *
     * HIGH-2 union: WHOOP_IMPORT / NOOP_COMPUTED carry the UNION of (active id) AND the canonical
     * "my-whoop": a re-added strap writes LIVE data under its fresh id while the WHOOP-export import (and
     * the computed history derived from it) stays anchored on the canonical id, so reading only the active
     * id would orphan that import on this record. The ids are ordered ACTIVE-FIRST, so the per-day pick in
     * [buildFor] takes the active (live/measured) row over the canonical (imported) one when both cover the
     * requested day. A single-WHOOP install resolves [activeStrapId] to "my-whoop" ⇒ a single id per source
     * and byte-identical behaviour.
     */
    private fun sourceIds(activeStrapId: String): List<Pair<FusionSource, List<String>>> = listOf(
        FusionSource.WHOOP_IMPORT to WhoopRepository.importedSourceIdsFor(activeStrapId),
        FusionSource.NOOP_COMPUTED to WhoopRepository.computedSourceIdsFor(activeStrapId),
        FusionSource.APPLE_HEALTH to listOf(WhoopRepository.APPLE_HEALTH_SOURCE),
        FusionSource.HEALTH_CONNECT to listOf(WhoopRepository.HEALTH_CONNECT_SOURCE),
        FusionSource.XIAOMI_BAND to listOf(FusionSource.XIAOMI_BAND.id),
    )

    /**
     * Build the [FusedRecord] for [day] ("yyyy-MM-dd"). Reads each source's row for the day, resolves each
     * metric, and degrades gracefully: a single contributing source ⇒ a plain record with no provenance
     * noise (the screen reads [FusedRecord.contributingSourceCount]). Empty when no source has the day.
     *
     * [activeStrapId] is the registry's active strap id (SPINE / #814): the strap + computed reads follow
     * it instead of a hardcoded "my-whoop". Defaults to "my-whoop" so existing callers / tests on a
     * single-WHOOP install are unaffected.
     */
    suspend fun buildFor(
        repo: WhoopRepository,
        day: String,
        activeStrapId: String = WhoopRepository.WHOOP_SOURCE,
    ): FusedRecord {
        // One row per source for the requested day (or null when that source has nothing that day).
        //
        // #799: a source contributes ONLY the day it ACTUALLY covers. `firstOrNull { it.day == day }`
        // matches the source's OWN row keyed to this exact day (each daily row is keyed by its own local
        // day at write time), so a single imported sleep row can never supply a value for a day it doesn't
        // cover (the "fused 8h57m every day" symptom). `repo.days(id)` is bounded per source and a missing
        // day is a clean null, dropping that source out of every metric for the day rather than carrying a
        // stale value forward. (firstOrNull over lastOrNull: day keys are unique per (deviceId, day) PK, so
        // either is the same single row; firstOrNull is the cheaper short-circuit.)
        val perSource: List<Pair<FusionSource, DailyMetric?>> = sourceIds(activeStrapId).map { (source, ids) ->
            // HIGH-2 union: a source may span MORE THAN ONE id (active strap ∪ canonical "my-whoop"). The ids
            // are active-FIRST, so `firstNotNullOfOrNull` takes the active (live/measured) row for the day and
            // only falls back to the canonical (imported) row when the active id doesn't cover it, so the import
            // is no longer orphaned after a re-add, and a single-id source is the same single read as before.
            val row = ids.firstNotNullOfOrNull { id ->
                runCatching { repo.days(id) }.getOrDefault(emptyList()).firstOrNull { it.day == day }
            }
            source to row
        }

        val contributingSources = perSource.count { it.second != null }

        val rows = ArrayList<FusedRow>()
        for (spec in METRICS) {
            val inputs = perSource.mapNotNull { (source, row) ->
                row?.let { WhoopRepository.dailyColumn(spec.key, it)?.let { v -> FusionInput(source, v) } }
            }
            val point = FusionResolver.resolve(spec.key, inputs) ?: continue
            rows.add(FusedRow(point = point, label = spec.label))
        }

        // Day owner: the single device that owns the day's displayed scores (lowest priority with data).
        val dayOwner = resolveDayOwner(perSource)

        return FusedRecord(
            rows = rows,
            dayOwner = dayOwner,
            contributingSourceCount = contributingSources,
        )
    }

    /** Pick the day's score-owner via [DayOwnerResolver]: active strap (0) beats imports/phone. */
    private fun resolveDayOwner(perSource: List<Pair<FusionSource, DailyMetric?>>): FusionSource? {
        val candidates = perSource.map { (source, row) ->
            DayOwnerResolver.Candidate(
                deviceId = source.id,
                priority = ownerPriority(source),
                hasData = row != null,
            )
        }
        val ownerId = DayOwnerResolver.resolve(day = "", lockedOwner = null, candidates = candidates) ?: return null
        return FusionSource.entries.firstOrNull { it.id == ownerId }
    }

    /** Day-owner priority (lower wins): a live strap owns the day over imports / phone aggregates. */
    private fun ownerPriority(source: FusionSource): Int = when (source) {
        FusionSource.WHOOP_IMPORT -> 1     // the strap's own banked day
        FusionSource.NOOP_COMPUTED -> 0    // on-device computed from the active strap = the live owner
        FusionSource.XIAOMI_BAND -> 1
        FusionSource.APPLE_HEALTH -> 2
        FusionSource.HEALTH_CONNECT -> 2
        FusionSource.NUTRITION_CSV -> 3
        FusionSource.LOCAL_CACHE -> 3
    }
}
