package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Mirror of the Swift BatteryEstimatorTests: same fixtures, same expectations (#713). */
class BatteryEstimatorTest {

    private val h = 3600L

    @Test fun nullWhenNoSamples() {
        assertNull(BatteryEstimator.estimate(emptyList(), BatteryEstimator.ratedLifeHoursWhoop5))
    }

    @Test fun measuredRateFromCleanDischarge() {
        // 100% to 90% over 10h is 1 %/h; at 90% that leaves 90h, from the user's own discharge.
        val e = BatteryEstimator.estimate(listOf(0L to 100.0, 10 * h to 90.0),
            BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(BatteryEstimator.Source.MEASURED, e.source)
        assertEquals(90.0, e.remainingHours, 1e-6)
        assertEquals(90.0, e.hoursRemaining, 1e-6)
        assertEquals(90.0 / 24, e.daysRemaining, 1e-6)
        assertEquals(90.0, e.currentSoc, 1e-6)
    }

    @Test fun ratedFallbackWhenSpanTooShort() {
        // A single reading has no span to fit, so it falls back to rated: 50 / (100/108) = 54h.
        val e = BatteryEstimator.estimate(listOf(0L to 50.0), BatteryEstimator.ratedLifeHoursWhoop4)!!
        assertEquals(BatteryEstimator.Source.RATED, e.source)
        assertEquals(54.0, e.remainingHours, 1e-6)
    }

    @Test fun chargeRestartsTheDischargeRun() {
        // Discharge 100->70, then a charge back to 100, then 100->88 over 6h. The rate is fit on the
        // post-charge segment only (2 %/h), never across the charge.
        val r = listOf(0L to 100.0, 4 * h to 70.0, 5 * h to 100.0, 11 * h to 88.0)
        val e = BatteryEstimator.estimate(r, BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(BatteryEstimator.Source.MEASURED, e.source)
        assertEquals(44.0, e.remainingHours, 1e-6)   // 88 / 2
    }

    @Test fun partialTopUpDoesNotInflateDaysLeft() {
        // #8: a partial top-up must NOT reset the discharge run like a full charge. Buffer is a long clean
        // discharge 100%->40% over 60h (1 %/h), a quick desk top-up 40->55 at 61h, then 55->53 over 3h. The
        // old scan anchored the run on the +15pp top-up and fit ~0.67 %/h on the 3h tail, inflating the
        // estimate. With the near-full guard the top-up is stepped over, the fit prefers the long pre-top-up
        // segment (1 %/h), and at 53% that is an honest ~53h, not the inflated ~79h.
        val r = listOf(0L to 100.0, 60 * h to 40.0, 61 * h to 55.0, 64 * h to 53.0)
        val e = BatteryEstimator.estimate(r, BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(BatteryEstimator.Source.MEASURED, e.source)
        assertEquals(53.0, e.currentSoc, 1e-6)
        assertEquals(53.0, e.remainingHours, 1e-6)   // 53 / (1 %/h), pre-top-up slope
    }

    @Test fun measuredFromRecentDischargeWithoutNearFullCharge() {
        // #919: a WHOOP 5.0 that never tops past 90% - SoC rises 16->52, then discharges 52->44 over 8h. The
        // old scan found no near-full anchor and fell back to the OLDEST (16%) reading, so the window netted
        // to a CHARGE (drop<0) and the estimate stayed on rated. Anchoring at the buffer's max (52%) fits the
        // real 1 %/h discharge -> measured, 44h. (Distinct from #8, whose buffer already starts at its max.)
        val r = listOf(0L to 16.0, 4 * h to 52.0, 12 * h to 44.0)
        val e = BatteryEstimator.estimate(r, BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(BatteryEstimator.Source.MEASURED, e.source)
        assertEquals(44.0, e.currentSoc, 1e-6)
        assertEquals(44.0, e.remainingHours, 1e-6)   // 52->44 = 8pp over 8h = 1 %/h; 44 / 1
    }

    @Test fun nearFullChargeStillResetsTheRun() {
        // The guard must NOT change a genuine near-full charge: discharge 100->20, charge back to 95 (>=90,
        // near-full), then 95->85 over 5h is 2 %/h. The run still resets on the near-full charge, source
        // measured, 85 / 2 = 42.5h. This pins that the near-full anchor still fires (no regression of #713).
        val r = listOf(0L to 100.0, 8 * h to 20.0, 9 * h to 95.0, 14 * h to 85.0)
        val e = BatteryEstimator.estimate(r, BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(BatteryEstimator.Source.MEASURED, e.source)
        assertEquals(42.5, e.remainingHours, 1e-6)   // 85 / 2, post-near-full-charge segment
    }

    @Test fun ratedFallbackWhenDropTooSmall() {
        // 100->99 over 10h is a 1% drop, under minDropPct(2), so it falls back to rated instead of
        // reporting a wild ~1000h. The estimate stays anchored to the latest SoC.
        val e = BatteryEstimator.estimate(listOf(0L to 100.0, 10 * h to 99.0),
            BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(BatteryEstimator.Source.RATED, e.source)
        assertEquals(285.12, e.remainingHours, 1e-6)   // 99 / (100/288)
    }

    @Test fun clampsToOneAndAHalfTimesRated() {
        // A slow drain near full charge must not report more than 1.5x the rated life. 100% to 90% over
        // 20h is 0.5 %/h, current 90% -> 180h raw, clamped to 108*1.5 = 162h.
        val e = BatteryEstimator.estimate(listOf(0L to 100.0, 20 * h to 90.0),
            BatteryEstimator.ratedLifeHoursWhoop4)!!
        assertEquals(BatteryEstimator.Source.MEASURED, e.source)
        assertEquals(162.0, e.remainingHours, 1e-6)   // clamped, not 200
    }

    @Test fun unsortedSamplesAreHandled() {
        // Same two points as the clean-discharge case but out of order: result must match.
        val e = BatteryEstimator.estimate(listOf(10 * h to 90.0, 0L to 100.0),
            BatteryEstimator.ratedLifeHoursWhoop5)!!
        assertEquals(BatteryEstimator.Source.MEASURED, e.source)
        assertEquals(90.0, e.remainingHours, 1e-6)
        assertEquals(90.0, e.currentSoc, 1e-6)
    }

    @Test fun labelSwitchesHoursToDaysAt48h() {
        assertEquals("~14h", BatteryEstimator.label(14.0))
        assertEquals("~4.5 days", BatteryEstimator.label(108.0))
    }
}
