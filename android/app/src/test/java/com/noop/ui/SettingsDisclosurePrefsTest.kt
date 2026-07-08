package com.noop.ui

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the Settings "Advanced" disclosure persistence (S3). The one fact that must never regress is the
 * DEFAULT: a fresh install reads collapsed, so a first-run user sees the everyday handful of sections
 * rather than the full wall of cards. Also guards that the key matches the iOS @AppStorage key so a
 * backup/restore round-trip carries the choice across platforms, and that a write round-trips.
 *
 * The project ships NO Robolectric (junit only), so the REAL [SettingsDisclosurePrefs] runs over an
 * in-memory [FakeSharedPreferences] that reproduces the SharedPreferences read/write contract (the same
 * approach TestCentreTest uses).
 */
class SettingsDisclosurePrefsTest {

    @Test
    fun freshInstall_defaultsCollapsed() {
        // Nothing written yet: the disclosure must default closed so first-run isn't a wall of cards.
        assertFalse(SettingsDisclosurePrefs.DEFAULT_OPEN)
        assertFalse(SettingsDisclosurePrefs.read(FakeSharedPreferences()))
    }

    @Test
    fun keyMatchesIosAppStorageKey() {
        // iOS uses @AppStorage("settingsAdvancedOpen"); Android namespaces it under noop. so a .noopbak
        // restore carries the choice. The suffix must stay in lockstep with the Swift key.
        assertEquals("noop.settingsAdvancedOpen", SettingsDisclosurePrefs.KEY)
    }

    @Test
    fun write_thenRead_roundTrips() {
        val prefs = FakeSharedPreferences()
        SettingsDisclosurePrefs.write(prefs, true)
        assertTrue(SettingsDisclosurePrefs.read(prefs))
        SettingsDisclosurePrefs.write(prefs, false)
        assertFalse(SettingsDisclosurePrefs.read(prefs))
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
