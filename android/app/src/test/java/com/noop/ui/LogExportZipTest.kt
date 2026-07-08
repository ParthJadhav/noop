package com.noop.ui

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.util.zip.ZipInputStream

/** Twin of the Swift FileExportZipTests: zipEntries produces a valid archive with both entries. */
class LogExportZipTest {

    @Test fun zipEntriesRoundTripsTwoEntries() {
        val entries = listOf(
            "report.txt" to "hello report".toByteArray(),
            "meta.json" to "{\"schema\":1}".toByteArray())
        val bytes = LogExport.zipEntries(entries)
        assertTrue(bytes!!.isNotEmpty())

        val seen = HashMap<String, ByteArray>()
        ZipInputStream(ByteArrayInputStream(bytes)).use { zin ->
            var e = zin.nextEntry
            while (e != null) {
                seen[e.name] = zin.readBytes()
                e = zin.nextEntry
            }
        }
        assertEquals(setOf("report.txt", "meta.json"), seen.keys)
        assertArrayEquals("hello report".toByteArray(), seen["report.txt"])
    }

    @Test fun zipEntriesEmptyReturnsNull() {
        assertNull(LogExport.zipEntries(emptyList()))
    }
}
