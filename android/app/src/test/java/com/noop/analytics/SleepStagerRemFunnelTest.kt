package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RrInterval
import com.noop.data.RespSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests SleepStager's read-only REM-funnel diagnostic (#688). 0% REM over a whole night is
 * physiologically implausible (healthy adults cycle ~20–25% REM), so a 0%-REM hypnogram — common on
 * WHOOP 4.0 nights staged WITHOUT a respiration channel — points at the STAGER. The diagnostic
 * re-runs the exact staging funnel and counts WHERE REM was lost, changing nothing. Faithful Kotlin
 * mirror of the REM-funnel cases in SleepStagerTests.swift.
 */
class SleepStagerRemFunnelTest {

    private val dev = "test"

    /** 2025-06-10 00:00:00 UTC — an arbitrary fixed midnight (ref % 86400 == 0). */
    private val refMidnight = 1_749_513_600L
    private fun startAtHour(hourUTC: Int): Long = refMidnight + hourUTC * 3_600L

    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    private fun hrStream(start: Long, durationS: Int, bpm: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    /** EpochFeatures constructor: index, midTs, count, moveFrac, ckSleep, hr, hrVar, rmssd, sdnn, respRate, rrv, clock. */
    private fun feature(
        moveFrac: Double, hr: Double, hrVar: Double, rmssd: Double, rrv: Double,
    ): SleepStager.EpochFeatures = SleepStager.EpochFeatures(
        index = 0, midTs = 0.0, count = 0.0, moveFrac = moveFrac, ckSleep = true,
        hr = hr, hrVar = hrVar, rmssd = rmssd, sdnn = 0.0, respRate = 14.0, rrv = rrv, clock = 0.5,
    )

    // Percentiles: hrLo=55, hrHi=70 (hr=80 is high), rmssdHi=50, hrvarHi=1 (hrVar=5 is high),
    // rrvHi=1 (rrv=2 is irregular), rrvLo=0.5. A still+cardiac+irregular epoch clears all REM gates.
    private fun reason(f: SleepStager.EpochFeatures): SleepStager.REMRejectReason =
        SleepStager.remRejectReason(f, hrLo = 55.0, hrHi = 70.0, rmssdHi = 50.0,
            hrvarHi = 1.0, rrvHi = 1.0, rrvLo = 0.5)

    @Test
    fun remRejectReasonAttributesEachGate() {
        // remEligible: still + cardiac-activated (hr high) + irregular resp.
        assertEquals("still + cardiac + irregular resp → REM",
            SleepStager.REMRejectReason.REM_ELIGIBLE, reason(feature(0.0, 80.0, 5.0, 20.0, 2.0)))

        // notStill: moving body, hr mid (60) + flat HR-variability → not cardiac, so NOT wake; the
        // REM rule fails first on stillness.
        assertEquals("moving body (no cardiac) → blocked notStill",
            SleepStager.REMRejectReason.NOT_STILL, reason(feature(0.5, 60.0, 0.0, 60.0, 2.0)))

        // noCardiacActivation: still + irregular resp but HR mid + flat HR-variability.
        assertEquals("still + irregular resp but no cardiac → blocked",
            SleepStager.REMRejectReason.NO_CARDIAC_ACTIVATION, reason(feature(0.0, 60.0, 0.0, 20.0, 2.0)))

        // respRegular: still + cardiac-activated but resp present and REGULAR (rrv ≤ rrvLo). hr=80 is
        // not low so it can't win deep — safe to isolate the respRegular reason.
        assertEquals("still + cardiac but regular resp → blocked respRegular",
            SleepStager.REMRejectReason.RESP_REGULAR, reason(feature(0.0, 80.0, 5.0, 20.0, 0.1)))

        // noRespFallbackBar: resp ABSENT (rrv NaN) and the no-resp REM bar (needs BOTH hrHigh AND
        // hrvarHigh) unmet — here hr high but hrVar flat.
        assertEquals("resp absent + no-resp bar unmet → blocked",
            SleepStager.REMRejectReason.NO_RESP_FALLBACK_BAR,
            reason(feature(0.0, 80.0, 0.0, 20.0, Double.NaN)))
    }

    @Test
    fun remRejectReasonNoRespFallbackIsRemEligible() {
        // The no-resp REM fallback: still + HR-high + HR-variability-high + resp absent → REM eligible.
        assertEquals(SleepStager.REMRejectReason.REM_ELIGIBLE,
            reason(feature(0.0, 80.0, 5.0, 20.0, Double.NaN)))
    }

    @Test
    fun nullWhenNoGravity() {
        assertNull(SleepStager.remFunnelDiagnostic(0L, 1800L, emptyList(), emptyList(), emptyList(), emptyList()))
    }

    @Test
    fun zeroRemNightSurfacesRespAbsent() {
        // A WHOOP-4.0-style night: still body, low HR, NO respiration and NO R-R → the classifier can
        // never reach REM (the no-resp fallback needs cardiac activation, which a flat low-HR still
        // night lacks). The hypnogram is 0% REM; the diagnostic must say WHY: resp ABSENT, and every
        // sleep epoch attributed to a concrete non-REM reason.
        val start = startAtHour(2)
        val dur = 90 * 60
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50) // flat, low → no cardiac activation
        val diag = SleepStager.remFunnelDiagnostic(
            start, start + dur, grav, hr, emptyList<RrInterval>(), emptyList<RespSample>())
        assertNotNull(diag)
        val d = diag!!
        assertTrue("a flat still low-HR no-resp night has 0% REM", d.isZeroREM)
        assertEquals(0, d.remAfterReimpose)
        assertFalse("no resp and no R-R → respChannelPresent false", d.respChannelPresent)
        assertTrue("the sleep period must contain epochs to explain", d.sleepEpochs > 0)
        // Conservation: every sleep epoch is attributed to exactly one bucket at the classifier mouth.
        val attributed = d.remAtClassify + d.wonOtherStage + d.blockedNotStill +
            d.blockedNoCardiacActivation + d.blockedRespRegular + d.blockedNoRespFallbackBar
        assertEquals("per-epoch reasons must partition the sleep epochs", d.sleepEpochs, attributed)
        assertTrue("summary surfaces the absent resp channel", d.summary.contains("resp=ABSENT"))
    }

    @Test
    fun diagnosticIsReadOnly() {
        // The diagnostic must not perturb the hypnogram stageSession produces for the same window.
        val start = startAtHour(2)
        val dur = 90 * 60
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)
        val before = SleepStager.stageSession(start, start + dur, grav, hr, emptyList(), emptyList())
        SleepStager.remFunnelDiagnostic(start, start + dur, grav, hr, emptyList(), emptyList())
        val after = SleepStager.stageSession(start, start + dur, grav, hr, emptyList(), emptyList())
        assertEquals("remFunnelDiagnostic must not change the staged hypnogram", before, after)
    }

    // ── #705: PPG-derived / sparse-cardiac WAKE over-report ────────────────────
    // On a WHOOP 5/MG the PPG-derived HR makes per-epoch hrVar noisy, so the high hrVar bar fired on
    // still, low-HR sleep and the WAKE rule flipped those epochs to wake (40%+ wake nights). The
    // sparse-cardiac gate vets the wake cardiac half by HR only. Faithful mirror of the #705 cases in
    // SleepStagerTests.swift.

    // A still, low-HR sleep epoch with INFLATED hrVar but normal HR and a touch of motion (over the
    // wake bar). Missing R-R + resp (sparse/PPG).
    private fun ppgWakeEpoch(): SleepStager.EpochFeatures = SleepStager.EpochFeatures(
        index = 0, midTs = 0.0, count = 0.0, moveFrac = 0.16, ckSleep = true,
        hr = 60.0, hrVar = 200.0, rmssd = Double.NaN, sdnn = 0.0, respRate = 14.0, rrv = Double.NaN, clock = 0.5,
    )

    @Test
    fun sparseCardiacDoesNotPromoteStillSleepToWakeOnHrVarAlone_705() {
        // Dense rule: hrvarHigh alone clears the WAKE cardiac bar → wake (old behaviour).
        val dense = SleepStager.classifyOne(ppgWakeEpoch(),
            hrLo = 55.0, hrHi = 90.0, rmssdHi = 50.0, hrvarHi = 100.0, rrvHi = 1.0, rrvLo = 0.5,
            cardiacSparse = false)
        assertEquals("dense 4.0 night keeps the full hrHigh||hrvarHigh wake signal", "wake", dense)

        // Sparse/PPG rule: noisy hrVar is down-weighted for the wake promotion → no longer wake.
        val sparse = SleepStager.classifyOne(ppgWakeEpoch(),
            hrLo = 55.0, hrHi = 90.0, rmssdHi = 50.0, hrvarHi = 100.0, rrvHi = 1.0, rrvLo = 0.5,
            cardiacSparse = true)
        assertNotEquals("a sparse/PPG night must not flip still low-HR sleep to wake on hrVar alone", "wake", sparse)
    }

    @Test
    fun cardiacSparseFlagFiresOnMostlyMissingRmssd_705() {
        val withRR = feature(0.0, 55.0, 0.0, 40.0, Double.NaN)
        val noRR = feature(0.0, 55.0, 0.0, Double.NaN, Double.NaN)
        assertTrue("3/4 epochs missing R-R is sparse-cardiac",
            SleepStager.isCardiacSparse(listOf(noRR, noRR, noRR, withRR)))
        assertFalse("1/4 epochs missing R-R is a dense (4.0-style) night",
            SleepStager.isCardiacSparse(listOf(withRR, withRR, withRR, noRR)))
        assertFalse("empty session is not sparse", SleepStager.isCardiacSparse(emptyList()))
    }

    @Test
    fun stillPpgNightNoLongerScoresMostlyWake_705() {
        // Fixed bars (deterministic): a still, low-HR (52) epoch with a touch of motion (0.16) and
        // inflated hrVar (200), no finite R-R/resp. 9/10 such; 1/10 a real HR-elevated awakening (80).
        fun epoch(hr: Double, hrVar: Double): SleepStager.EpochFeatures = SleepStager.EpochFeatures(
            index = 0, midTs = 0.0, count = 0.0, moveFrac = 0.16, ckSleep = true,
            hr = hr, hrVar = hrVar, rmssd = Double.NaN, sdnn = 0.0, respRate = 14.0, rrv = Double.NaN, clock = 0.5,
        )
        val night = (0 until 40).map { i ->
            if (i % 10 == 9) epoch(80.0, 200.0) else epoch(52.0, 200.0)
        }
        fun wakeShare(cardiacSparse: Boolean): Double {
            val labels = night.map {
                SleepStager.classifyOne(it, hrLo = 48.0, hrHi = 70.0, rmssdHi = 50.0,
                    hrvarHi = 120.0, rrvHi = 1.0, rrvLo = 0.5, cardiacSparse = cardiacSparse)
            }
            return labels.count { it == "wake" }.toDouble() / labels.size.toDouble()
        }
        // Dense rule reproduces the bug: almost the whole night reads wake.
        assertTrue("dense rule still over-reports wake on a noisy-hrVar night (reproduces #705)",
            wakeShare(false) > 0.80)
        // Sparse-cardiac gate: only the real HR-elevated awakenings stay wake (~10%).
        assertTrue("a still PPG night must not be classified as mostly wake (was 40%+ before #705)",
            wakeShare(true) < 0.40)
    }
}
