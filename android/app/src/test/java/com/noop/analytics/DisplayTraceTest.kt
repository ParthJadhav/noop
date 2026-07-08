package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the exact line shapes the Display & Performance test mode emits and the readout parsers that read
 * them back, so a shared report reads identically on Android, iOS and macOS (the Swift DisplayTraceTests
 * pins the same shapes). Pure JVM: no Robolectric, no Mockito, no Choreographer, no platform read.
 */
class DisplayTraceTest {

    private fun sampleMetrics() = DisplayMetrics(
        horizontalSizeClass = "compact", verticalSizeClass = "regular",
        widthPt = 390.0, heightPt = 844.0, scale = 3.0,
        safeTop = 47.0, safeBottom = 34.0, safeLeading = 0.0, safeTrailing = 0.0,
        dynamicType = "L", orientation = "portrait", theme = "dark",
    )

    @Test
    fun deviceMetricsLineShape() {
        assertEquals(
            "deviceMetrics size=390x844pt @3.0x sizeClass=compact/regular " +
                "safeArea=t47 b34 l0 r0 dynamicType=L orientation=portrait theme=dark",
            DisplayTrace.deviceMetricsLine(sampleMetrics()),
        )
    }

    @Test
    fun deviceMetricsLineDegradesNullsToNa() {
        // Android has no size class; a null must print "n/a", never a fabricated value. The Android live
        // metrics put the font scale in dynamicType, so this also exercises a "1.30" style label.
        val m = DisplayMetrics(
            horizontalSizeClass = null, verticalSizeClass = null,
            widthPt = 411.0, heightPt = 891.0, scale = 2.75,
            safeTop = 0.0, safeBottom = 0.0, safeLeading = 0.0, safeTrailing = 0.0,
            dynamicType = "1.30", orientation = "portrait", theme = "light",
        )
        assertEquals(
            "deviceMetrics size=411x891pt @2.8x sizeClass=n/a/n/a " +
                "safeArea=t0 b0 l0 r0 dynamicType=1.30 orientation=portrait theme=light",
            DisplayTrace.deviceMetricsLine(m),
        )
    }

    @Test
    fun scaleUnknownPrintsQuestionMark() {
        val m = sampleMetrics().copy(scale = 0.0)
        assertTrue(DisplayTrace.deviceMetricsLine(m).contains("@?x"))
    }

    @Test
    fun frameSummaryLineShape() {
        assertEquals(
            "frameSummary frames=60 mean=16.7ms p95=18.4ms hitches=2 worst=41.9ms threshold=33.0ms",
            DisplayTrace.frameSummaryLine(
                frames = 60, meanMs = 16.71, p95Ms = 18.4, hitches = 2, worstMs = 41.93, hitchThresholdMs = 33.0,
            ),
        )
    }

    @Test
    fun memoryHighWaterLineShape() {
        // 187.46 is unambiguously above .45 in IEEE 754 (187.45 stores as 187.4499... and rounds DOWN),
        // so %.1f gives 187.5 identically on Kotlin and Swift. The input exercises round-up at the second
        // decimal without depending on round-half-even of a non-representable .45.
        assertEquals("memoryHighWater peak=187.5MB", DisplayTrace.memoryHighWaterLine(187.46))
    }

    // CAPTURE-D (#797): the data-volume line

    @Test
    fun dataVolumeLineShape() {
        assertEquals(
            "dataVolume dbRows=1234567 importedDays=420 workouts=88 lastRenderRows=512",
            DisplayTrace.dataVolumeLine(
                DataVolume(dbRows = 1_234_567, importedDays = 420, workouts = 88, lastRenderRows = 512),
            ),
        )
    }

    @Test
    fun dataVolumeLineNullRenderRowsPrintsNa() {
        // No render measured yet must print "n/a", never a fabricated 0. Byte-identical to the Swift line.
        val line = DisplayTrace.dataVolumeLine(
            DataVolume(dbRows = 0, importedDays = 0, workouts = 0, lastRenderRows = null),
        )
        assertEquals("dataVolume dbRows=0 importedDays=0 workouts=0 lastRenderRows=n/a", line)
    }

    @Test
    fun readoutParsesLatestDeviceMetricsAndFrameSummary() {
        val tail = listOf(
            "[display] deviceMetrics size=320x568pt @2.0x sizeClass=n/a/n/a safeArea=t0 b0 l0 r0 dynamicType=1.00 orientation=portrait theme=light",
            "[display] frameSummary frames=60 mean=16.7ms p95=18.4ms hitches=0 worst=20.1ms threshold=33.0ms",
            "[display] deviceMetrics size=390x844pt @3.0x sizeClass=n/a/n/a safeArea=t47 b34 l0 r0 dynamicType=1.30 orientation=portrait theme=dark",
        )
        assertEquals(
            "size=390x844pt @3.0x sizeClass=n/a/n/a safeArea=t47 b34 l0 r0 dynamicType=1.30 orientation=portrait theme=dark",
            DisplayReadout.deviceMetricsNow(tail),
        )
        assertEquals(
            "frames=60 mean=16.7ms p95=18.4ms hitches=0 worst=20.1ms threshold=33.0ms",
            DisplayReadout.frameSummaryNow(tail),
        )
    }

    @Test
    fun readoutNullWhenNoLine() {
        assertNull(DisplayReadout.deviceMetricsNow(emptyList()))
        assertNull(
            DisplayReadout.frameSummaryNow(
                listOf("[display] deviceMetrics size=1x1pt @1.0x sizeClass=n/a/n/a safeArea=t0 b0 l0 r0 dynamicType=1.00 orientation=portrait theme=light"),
            ),
        )
    }
}
