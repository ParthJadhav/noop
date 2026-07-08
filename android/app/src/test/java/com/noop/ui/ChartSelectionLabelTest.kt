package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The LineChart tap/drag pinpoint label (#463). The overlay used to draw the RAW plotted value
 * unconditionally, so on Trends' Effort chart a tapped day printed the stored 0-100 figure (a bare
 * "13") beside a 0-21 converted axis. Callers can now inject the same formatter the axis uses;
 * with no formatter the raw near-integer-collapsing default is unchanged.
 */
class ChartSelectionLabelTest {

    @Test fun withoutAFormatterTheRawDefaultIsUnchanged() {
        // Near-integer values collapse to the bare integer, the exact "13" the reporter saw.
        assertEquals("13", lineChartSelectionLabel(13.0, null))
        assertEquals("13", lineChartSelectionLabel(12.98, null))
        // Clearly fractional values keep one decimal.
        assertEquals("9.4", lineChartSelectionLabel(9.4, null))
    }

    @Test fun aSuppliedFormatterOwnsTheLabel() {
        val toWhoopScale: (Double) -> String = { UnitFormatter.effortDisplay(it, EffortScale.WHOOP) }
        // The stored 13 renders as 2.7 on the 0-21 display scale, matching the axis column.
        assertEquals("2.7", lineChartSelectionLabel(13.0, toWhoopScale))
    }

    @Test fun theFormatterReceivesThePlottedValueVerbatim() {
        var seen: Double? = null
        lineChartSelectionLabel(41.5, { v -> seen = v; "x" })
        assertEquals(41.5, seen!!, 0.0)
    }
}
