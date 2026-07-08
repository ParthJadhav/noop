package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Twin of the Swift FileExportNameTests: same noop-<profile>-<platform>-v<version>-<stamp>.zip pattern. */
class LogExportNameTest {

    @Test fun bundleNamePattern() {
        // Fixed epoch so the yyMMdd-HHmm stamp is deterministic in the assertion structure.
        val name = LogExport.bundleName(profile = "sleep", platform = "android", version = "7.3.0", nowMs = 0L)
        assertTrue(name.startsWith("noop-sleep-android-v7.3.0-"))
        assertTrue(name.endsWith(".zip"))
        val stampPart = name.removePrefix("noop-sleep-android-v7.3.0-").removeSuffix(".zip")
        assertEquals(11, stampPart.length)  // YYMMDD-HHMM
        assertTrue(stampPart.contains("-"))
    }
}
