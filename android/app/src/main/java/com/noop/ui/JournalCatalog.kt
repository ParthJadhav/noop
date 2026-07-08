package com.noop.ui

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

// MARK: - Journal catalog v2 (#322 / task #53): rename + numeric type + group + order
//
// A journal item can now be renamed (display-only, the stored key stays put so imported WHOOP
// history still lines up), typed as numeric (a value + unit, not just yes/no), grouped, and
// reordered. The `canonical` string is the verbatim DB/engine key and is NEVER localised or
// rewritten; only `displayName` changes on a rename. Pure helpers here mirror the macOS
// JournalCatalogStore value-for-value so both platforms resolve, rename, and group identically.

/** A journal item's type: a plain yes/no toggle, or a numeric value with an optional unit label. */
sealed class JournalKind {
    object Bool : JournalKind()
    data class Numeric(val unit: String?) : JournalKind()

    val isNumeric: Boolean get() = this is Numeric
    /// The unit label if this is a numeric kind. Public accessor named `unitLabel`; the constructor
    /// property is `unit` so it does not shadow this and trip the hidden-member override error.
    val unitLabel: String? get() = (this as? Numeric)?.unit
}

/**
 * A user-visible grouping for related journal items (display + organisation only, never a scoring
 * change). Mirrors macOS `JournalGroup` value-for-value. The enum name is the stable persisted key;
 * [title] is the display label.
 */
enum class JournalGroup(val title: String) {
    Supplements("Supplements"),
    Nutrition("Nutrition"),
    Lifestyle("Lifestyle"),
    Health("Health"),
    Behaviour("Behaviour"),
    Other("Other");

    companion object {
        /** Fixed display order (matches macOS). Empty groups hide outside edit mode. */
        val displayOrder: List<JournalGroup> =
            listOf(Nutrition, Supplements, Lifestyle, Health, Behaviour, Other)

        fun fromKey(key: String): JournalGroup =
            entries.firstOrNull { it.name == key } ?: Other
    }
}

/**
 * One journal catalog item. [canonical] is the verbatim DB/engine key (the exact question string the
 * effects engine and the `journal` table join on), it is NEVER localised or rewritten, so a rename
 * or a re-import always folds onto one behaviour. [displayName] (a rename) and [kind] / [group] /
 * [sortIndex] are display + organisation only. Mirrors macOS `JournalCatalogItem`.
 */
data class JournalCatalogItem(
    /** The stable key. Rename NEVER touches this, so history (logged + imported) is preserved. */
    val canonical: String,
    /** The renamed display label, or null to render the canonical verbatim. */
    val displayName: String? = null,
    val kind: JournalKind = JournalKind.Bool,
    val group: JournalGroup = JournalGroup.Other,
    val sortIndex: Int = 0,
    val hidden: Boolean = false,
    /** True for a user-added question (deletable); false for a starter/imported one (hideable only). */
    val custom: Boolean = false,
) {
    /** What the UI renders: the rename if present, else the verbatim canonical. */
    val display: String get() = displayName ?: canonical
}

/**
 * The default group for each starter question (canonical -> group). Mirrors macOS
 * JournalCatalogStore.starterGroups value-for-value. Anything not listed falls to Other.
 */
val STARTER_JOURNAL_GROUPS: Map<String, JournalGroup> = mapOf(
    "Did you drink any alcohol?" to JournalGroup.Nutrition,
    "Did you have caffeine late in the day?" to JournalGroup.Nutrition,
    "Did you eat close to bedtime?" to JournalGroup.Nutrition,
    "Did you take magnesium?" to JournalGroup.Supplements,
    "Did you view a screen in bed?" to JournalGroup.Lifestyle,
    "Did you use a sauna?" to JournalGroup.Lifestyle,
    "Did you share your bed?" to JournalGroup.Lifestyle,
    "Did you read before bed?" to JournalGroup.Lifestyle,
    "Did you feel sick or ill?" to JournalGroup.Health,
    "Did you feel stressed?" to JournalGroup.Behaviour,
)

// MARK: - Pure catalog logic (JVM-testable; mirrors macOS)

/**
 * Fold the legacy custom/hidden arrays into v2 items (the one-time migration). Custom questions ->
 * Bool/Other custom items (ordered as they were); hidden starter/imported ones -> hidden markers; a
 * hidden custom keeps its flag on the single custom item (deduped by [normJournalKey], no dupe).
 * Mirrors macOS JournalCatalogStore.migrateLegacy value-for-value.
 */
fun migrateLegacyJournalCatalog(custom: List<String>, hidden: List<String>): List<JournalCatalogItem> {
    val out = ArrayList<JournalCatalogItem>()
    val seen = HashSet<String>()
    var i = 0
    for (q in custom) {
        val t = q.trim()
        val key = normJournalKey(q)
        if (t.isEmpty() || !seen.add(key)) continue
        out.add(JournalCatalogItem(canonical = t, kind = JournalKind.Bool, group = JournalGroup.Other,
            sortIndex = i, hidden = false, custom = true))
        i++
    }
    for (q in hidden) {
        val t = q.trim()
        val key = normJournalKey(q)
        if (t.isEmpty()) continue
        val idx = out.indexOfFirst { normJournalKey(it.canonical) == key }
        if (idx >= 0) {
            out[idx] = out[idx].copy(hidden = true)   // a hidden custom question
        } else if (seen.add(key)) {
            out.add(JournalCatalogItem(canonical = t, kind = JournalKind.Bool,
                group = STARTER_JOURNAL_GROUPS[t] ?: JournalGroup.Other,
                sortIndex = i, hidden = true, custom = false))
            i++
        }
    }
    return out
}

/**
 * Resolve the merged catalog into full v2 items, grouped and ordered for display. Imported + starter
 * + custom questions fold onto one canonical key (norm dedupe, #224); each carries the user's saved
 * displayName / kind / group / sortIndex (a starter with no saved item gets its default group and
 * Bool). Hidden items are dropped unless [includeHidden]. Mirrors macOS `resolvedItems`.
 */
fun resolveJournalItems(
    imported: List<String>,
    savedItems: List<JournalCatalogItem>,
    includeHidden: Boolean = false,
    starter: List<String> = STARTER_JOURNAL_QUESTIONS,
): List<JournalCatalogItem> {
    val byKey = HashMap<String, JournalCatalogItem>()
    for (it in savedItems) byKey[normJournalKey(it.canonical)] = it

    val out = ArrayList<JournalCatalogItem>()
    val seen = HashSet<String>()
    var fallbackIndex = (savedItems.maxOfOrNull { it.sortIndex } ?: -1) + 1
    for (q in imported + starter) {
        val t = q.trim()
        val key = normJournalKey(q)
        if (t.isEmpty() || !seen.add(key)) continue
        val saved = byKey[key]
        if (saved != null) {
            out.add(saved)
        } else {
            out.add(JournalCatalogItem(canonical = t, kind = JournalKind.Bool,
                group = STARTER_JOURNAL_GROUPS[t] ?: JournalGroup.Other,
                sortIndex = fallbackIndex, hidden = false, custom = false))
            fallbackIndex++
        }
    }
    for (it in savedItems) {
        if (it.custom && normJournalKey(it.canonical) !in seen) {
            seen.add(normJournalKey(it.canonical))
            out.add(it)
        }
    }
    return if (includeHidden) out else out.filterNot { it.hidden }
}

/**
 * Rename an item: set a display-only label. The stored [JournalCatalogItem.canonical] (the DB/engine
 * key) is untouched, so all history, logged AND imported, stays joined under the original question.
 * A blank name clears the rename. Materialises a starter item into [items] if not present. Returns the
 * new item list. Mirrors macOS `JournalCatalogStore.rename`.
 */
fun renameJournalItem(items: List<JournalCatalogItem>, canonical: String, displayName: String): List<JournalCatalogItem> {
    val trimmed = displayName.trim()
    return editJournalItem(items, canonical) { it.copy(displayName = if (trimmed.isEmpty()) null else trimmed) }
}

fun setJournalItemGroup(items: List<JournalCatalogItem>, canonical: String, group: JournalGroup): List<JournalCatalogItem> =
    editJournalItem(items, canonical) { it.copy(group = group) }

fun setJournalItemKind(items: List<JournalCatalogItem>, canonical: String, kind: JournalKind): List<JournalCatalogItem> =
    editJournalItem(items, canonical) { it.copy(kind = kind) }

fun setJournalItemSortIndex(items: List<JournalCatalogItem>, canonical: String, sortIndex: Int): List<JournalCatalogItem> =
    editJournalItem(items, canonical) { it.copy(sortIndex = sortIndex) }

/** Add a custom item of the given type + group. No-op if the canonical already exists. */
fun addCustomJournalItem(
    items: List<JournalCatalogItem>,
    canonical: String,
    kind: JournalKind = JournalKind.Bool,
    group: JournalGroup = JournalGroup.Other,
): List<JournalCatalogItem> {
    val t = canonical.trim()
    if (t.isEmpty()) return items
    val key = normJournalKey(t)
    if (items.any { normJournalKey(it.canonical) == key }) return items
    val next = (items.maxOfOrNull { it.sortIndex } ?: -1) + 1
    return items + JournalCatalogItem(canonical = t, kind = kind, group = group,
        sortIndex = next, hidden = false, custom = true)
}

/**
 * Remove an item: a custom question is deleted outright; a starter/imported one is hidden
 * (restorable). Mirrors macOS `remove`.
 */
fun removeJournalItem(items: List<JournalCatalogItem>, canonical: String): List<JournalCatalogItem> {
    val key = normJournalKey(canonical)
    val existing = items.firstOrNull { normJournalKey(it.canonical) == key }
    return if (existing?.custom == true) {
        items.filterNot { normJournalKey(it.canonical) == key }
    } else {
        editJournalItem(items, canonical) { it.copy(hidden = true) }
    }
}

fun restoreJournalItem(items: List<JournalCatalogItem>, canonical: String): List<JournalCatalogItem> {
    val key = normJournalKey(canonical)
    return items.map { if (normJournalKey(it.canonical) == key) it.copy(hidden = false) else it }
}

/** The display label for a canonical key: the user's rename, or the verbatim canonical. */
fun journalDisplayName(items: List<JournalCatalogItem>, canonical: String): String {
    val key = normJournalKey(canonical)
    return items.firstOrNull { normJournalKey(it.canonical) == key }?.displayName ?: canonical.trim()
}

/** Upsert-and-edit one item by canonical, materialising a starter with its defaults if absent. */
private fun editJournalItem(
    items: List<JournalCatalogItem>,
    canonical: String,
    mutate: (JournalCatalogItem) -> JournalCatalogItem,
): List<JournalCatalogItem> {
    val key = normJournalKey(canonical)
    val idx = items.indexOfFirst { normJournalKey(it.canonical) == key }
    if (idx >= 0) {
        return items.toMutableList().also { it[idx] = mutate(it[idx]) }
    }
    val t = canonical.trim()
    val next = (items.maxOfOrNull { it.sortIndex } ?: -1) + 1
    val fresh = JournalCatalogItem(canonical = t,
        group = STARTER_JOURNAL_GROUPS[t] ?: JournalGroup.Other,
        sortIndex = next, hidden = false, custom = false)
    return items + mutate(fresh)
}

// MARK: - JSON persistence (SharedPreferences, single blob), mirrors the macOS "journal.catalog.v2" key

fun encodeJournalCatalog(items: List<JournalCatalogItem>): String {
    val arr = JSONArray()
    for (it in items) {
        val o = JSONObject()
        o.put("canonical", it.canonical)
        it.displayName?.let { d -> o.put("displayName", d) }
        o.put("kind", if (it.kind.isNumeric) "numeric" else "bool")
        it.kind.unitLabel?.let { u -> o.put("unitLabel", u) }
        o.put("group", it.group.name)
        o.put("sortIndex", it.sortIndex)
        o.put("hidden", it.hidden)
        o.put("custom", it.custom)
        arr.put(o)
    }
    return arr.toString()
}

fun decodeJournalCatalog(json: String): List<JournalCatalogItem> {
    if (json.isBlank()) return emptyList()
    val out = ArrayList<JournalCatalogItem>()
    val arr = runCatching { JSONArray(json) }.getOrNull() ?: return emptyList()
    for (i in 0 until arr.length()) {
        val o = arr.optJSONObject(i) ?: continue
        val canonical = o.optString("canonical", "")
        if (canonical.isEmpty()) continue
        val kind = if (o.optString("kind", "bool") == "numeric") {
            JournalKind.Numeric(if (o.has("unitLabel")) o.optString("unitLabel") else null)
        } else JournalKind.Bool
        out.add(
            JournalCatalogItem(
                canonical = canonical,
                displayName = if (o.has("displayName")) o.optString("displayName") else null,
                kind = kind,
                group = JournalGroup.fromKey(o.optString("group", "Other")),
                sortIndex = o.optInt("sortIndex", i),
                hidden = o.optBoolean("hidden", false),
                custom = o.optBoolean("custom", false),
            ),
        )
    }
    return out
}

// MARK: - SharedPreferences-backed store accessors (the one-time legacy fold lives here)

private const val JOURNAL_CATALOG_V2_KEY = "noop.journalCatalogV2"

/**
 * Load the v2 catalog items. On first run (no v2 blob) folds the legacy custom/hidden arrays into
 * items once and persists them, then never reads the legacy keys again. Mirrors macOS init().
 */
fun loadJournalCatalogItems(context: Context): List<JournalCatalogItem> {
    val prefs = context.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
    val blob = prefs.getString(JOURNAL_CATALOG_V2_KEY, null)
    if (blob != null) return decodeJournalCatalog(blob)
    val migrated = migrateLegacyJournalCatalog(
        custom = loadCustomJournalQuestions(context),
        hidden = loadHiddenJournalQuestions(context),
    )
    saveJournalCatalogItems(context, migrated)
    return migrated
}

fun saveJournalCatalogItems(context: Context, items: List<JournalCatalogItem>) {
    context.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
        .edit().putString(JOURNAL_CATALOG_V2_KEY, encodeJournalCatalog(items)).apply()
}
