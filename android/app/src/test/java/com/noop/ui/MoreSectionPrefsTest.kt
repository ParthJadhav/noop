package com.noop.ui

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the More-page section-expansion persistence (#860 item 2) - the Android twin of the iOS
 * `MoreSectionPrefsTests`. The behaviour that must never regress: the user's expanded/collapsed choice
 * SURVIVES leaving + re-entering the More page (and relaunch) instead of resetting to the seed every visit.
 * These exercise the REAL [MoreSectionPrefs] over an in-memory [FakeSharedPreferences] (the project ships
 * no Robolectric), and lock it in lockstep with the iOS twin (same key suffix, same CSV encoding, same
 * Insights+Body default).
 */
class MoreSectionPrefsTest {

    @Test
    fun keyMatchesIosAppStorageSuffix() {
        // iOS @AppStorage("more.expandedSections"); Android namespaces it under noop.
        assertEquals("noop.more.expandedSections", MoreSectionPrefs.KEY)
    }

    @Test
    fun encodeIsSortedAndDeterministic() {
        assertEquals("App,Body,Insights", MoreSectionPrefs.encode(setOf("Body", "App", "Insights")))
        assertEquals("Body,Insights", MoreSectionPrefs.encode(setOf("Insights", "Body")))
        assertEquals("", MoreSectionPrefs.encode(emptySet()))
    }

    @Test
    fun encodeDecodeRoundTrips() {
        for (set in listOf(
            emptySet(),
            setOf("Data"),
            setOf("Insights", "Body"),
            setOf("Insights", "Body", "Data", "App"),
        )) {
            assertEquals(set, MoreSectionPrefs.decode(MoreSectionPrefs.encode(set)))
        }
    }

    @Test
    fun decodeIgnoresBlankAndStrayTokens() {
        assertEquals(setOf("Insights", "Body"), MoreSectionPrefs.decode("Insights, ,Body,"))
        assertEquals(setOf("Data"), MoreSectionPrefs.decode("  Data  "))
    }

    @Test
    fun freshInstall_readReturnsTheSeedDefault() {
        // Nothing written yet: read falls back to the supplied seed (Insights + Body).
        val seed = setOf("Insights", "Body")
        assertEquals(seed, MoreSectionPrefs.read(FakeSharedPreferences(), seed))
    }

    @Test
    fun collapsedAllPersistsAsEmptySet_notTheSeed() {
        // A user who collapses EVERY group stores "" and must keep them all collapsed across visits - the
        // empty string is a valid persisted state, NOT a fall-back to the seed.
        val prefs = FakeSharedPreferences()
        MoreSectionPrefs.write(prefs, emptySet())
        val seed = setOf("Insights", "Body")
        assertEquals(emptySet<String>(), MoreSectionPrefs.read(prefs, seed))
        assertNotEquals(seed, MoreSectionPrefs.read(prefs, seed))
    }

    @Test
    fun write_thenRead_roundTrips() {
        val prefs = FakeSharedPreferences()
        MoreSectionPrefs.write(prefs, setOf("Insights", "Body", "Data"))
        assertEquals(setOf("Insights", "Body", "Data"), MoreSectionPrefs.read(prefs, emptySet()))
        assertTrue(prefs.contains(MoreSectionPrefs.KEY))
    }

    /** A minimal in-memory SharedPreferences: enough of the read/write contract for the helper above. */
    private class FakeSharedPreferences : SharedPreferences {
        val map = HashMap<String, Any?>()

        override fun getBoolean(key: String, defValue: Boolean): Boolean = map[key] as? Boolean ?: defValue
        override fun getLong(key: String, defValue: Long): Long = map[key] as? Long ?: defValue
        override fun getString(key: String, defValue: String?): String? = map[key] as? String ?: defValue
        override fun getInt(key: String, defValue: Int): Int = map[key] as? Int ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = map[key] as? Float ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
            map[key] as? MutableSet<String> ?: defValues
        override fun getAll(): MutableMap<String, *> = HashMap(map)
        override fun contains(key: String): Boolean = map.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}

        override fun edit(): SharedPreferences.Editor = FakeEditor(this)

        private class FakeEditor(private val prefs: FakeSharedPreferences) : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private val removals = HashSet<String>()
            override fun putString(key: String, value: String?): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor { pending[key] = values; return this }
            override fun putInt(key: String, value: Int): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putLong(key: String, value: Long): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putFloat(key: String, value: Float): SharedPreferences.Editor { pending[key] = value; return this }
            override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor { pending[key] = value; return this }
            override fun remove(key: String): SharedPreferences.Editor { removals.add(key); return this }
            override fun clear(): SharedPreferences.Editor { prefs.map.clear(); return this }
            override fun commit(): Boolean { flush(); return true }
            override fun apply() { flush() }
            private fun flush() {
                for (k in removals) prefs.map.remove(k)
                prefs.map.putAll(pending)
            }
        }
    }
}
