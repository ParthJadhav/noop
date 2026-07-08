package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Swift-parity twin of IllnessDistanceTests.swift, the alternative Mahalanobis illness distance and the
 * REQUIRED fire-rate comparison vs the existing per-signal z-sum over the illness corpus at threshold 2.5.
 */
class IllnessDistanceTest {

    @Test
    fun identityDistanceIsEuclideanNorm() {
        val r = IllnessDistance.evaluate(IllnessDistance.FeatureVector(restingHR = 3.0, rmssd = 3.0))
        assertEquals(4.242640687119285, r.distance, 1e-6)
        assertEquals(2, r.deviatingFeatures)
        assertFalse(r.usedDiagonalFallback)
        assertTrue("D > 2.5 and 2 deviating features -> fires", r.fires)
    }

    @Test
    fun correlationDiscountsSharedVariance() {
        val corr = listOf(listOf(1.0, 0.8), listOf(0.8, 1.0))
        val indep = IllnessDistance.evaluate(IllnessDistance.FeatureVector(restingHR = 3.0, rmssd = 3.0))
        val correlated = IllnessDistance.evaluate(
            IllnessDistance.FeatureVector(restingHR = 3.0, rmssd = 3.0), correlation = corr)
        assertEquals(3.162276781758283, correlated.distance, 1e-5)
        assertTrue("correlated co-movement counts as one move, not two", correlated.distance < indep.distance)
    }

    @Test
    fun wellnessWardSignalDoesNotCountAsDeviating() {
        val corr = listOf(listOf(1.0, 0.8), listOf(0.8, 1.0))
        val r = IllnessDistance.evaluate(
            IllnessDistance.FeatureVector(restingHR = 3.0, rmssd = -3.0), correlation = corr)
        assertTrue(r.distance > IllnessDistance.distanceThreshold)
        assertEquals(1, r.deviatingFeatures)
        assertFalse("a big D driven by a wellness-ward coordinate must not fire", r.fires)
    }

    @Test
    fun emptyVectorDoesNotFire() {
        val r = IllnessDistance.evaluate(IllnessDistance.FeatureVector())
        assertEquals(0.0, r.distance, 0.0)
        assertEquals(0, r.deviatingFeatures)
        assertFalse(r.fires)
    }

    @Test
    fun singularCorrelationIsRegularizedToFinite() {
        // A perfectly collinear (rank-1) correlation is singular; the Tikhonov ridge regularizes it to a
        // FINITE distance (no NaN/Inf), and collinear co-movement is discounted (two perfectly correlated
        // features both up count as ONE effective move), so D is well below the independent 4.24. Swift twin.
        val singular = listOf(listOf(1.0, 1.0), listOf(1.0, 1.0))
        val r = IllnessDistance.evaluate(
            IllnessDistance.FeatureVector(restingHR = 3.0, rmssd = 3.0), correlation = singular)
        assertTrue(r.distance.isFinite())
        assertTrue(r.distance > 0.0)
        assertTrue("collinear co-movement is one effective move, not two", r.distance < 4.2426)
    }

    @Test
    fun diagonalFallbackOnDegenerateMatrix() {
        // Directly exercise the singular fallback: a zero matrix has no usable pivot, so invertOrDiagonal
        // returns its finite diagonal inverse (degenerate diagonals mapped to 1) rather than NaN/Inf.
        val (inv, fellBack) = IllnessDistance.invertOrDiagonal(
            arrayOf(doubleArrayOf(0.0, 0.0), doubleArrayOf(0.0, 0.0)))
        assertTrue(fellBack)
        assertTrue(inv.all { row -> row.all { it.isFinite() } })
    }

    @Test
    fun mahalanobisFireRateDoesNotBalloonOrSilence() {
        val corpus = illnessCorpus()

        fun zSumFires(v: List<Double>): Boolean =
            v.count { it >= IllnessDistance.featureZThreshold } >= IllnessDistance.minDeviatingFeatures

        fun mahaFires(v: List<Double>): Boolean =
            IllnessDistance.evaluate(IllnessDistance.FeatureVector(
                restingHR = v[0], rmssd = v[1], skinTemp = v[2], respiration = v[3])).fires

        val zCount = corpus.count { zSumFires(it) }
        val mCount = corpus.count { mahaFires(it) }
        assertTrue(corpus.isNotEmpty())
        val lower = (zCount * 0.75).toInt()
        val upper = kotlin.math.ceil(zCount * 1.25).toInt()
        assertTrue("Mahalanobis path must not SILENCE alerts vs the z-sum", mCount >= lower)
        assertTrue("Mahalanobis path must not BALLOON alerts vs the z-sum", mCount <= upper)
        for (v in corpus) {
            assertEquals("z-sum and Mahalanobis disagree on $v", zSumFires(v), mahaFires(v))
        }
    }

    /** 60-case deterministic corpus identical to the Swift twin. */
    private fun illnessCorpus(): List<List<Double>> = listOf(
        // Strong multi-signal illness nights.
        listOf(3.2, 3.0, 3.5, 2.8), listOf(4.1, 2.9, 3.3, 3.0), listOf(2.6, 3.4, 2.7, 2.5),
        listOf(3.8, 4.0, 3.9, 3.6), listOf(2.9, 2.8, 3.1, 0.4), listOf(3.5, 3.2, 0.2, 3.0),
        listOf(4.4, 0.1, 3.0, 2.7), listOf(2.7, 3.6, 3.4, 1.1), listOf(3.0, 3.0, 3.0, 3.0),
        listOf(2.5, 2.6, 2.9, 2.4), listOf(3.9, 3.1, 1.0, 2.8), listOf(3.3, 0.5, 3.2, 3.4),
        listOf(2.8, 3.7, 2.6, 0.3), listOf(4.0, 2.5, 2.5, 2.5), listOf(3.1, 3.3, 3.5, 3.7),
        // Mild 2-signal nights.
        listOf(2.3, 2.2, 0.5, -0.4), listOf(2.1, 0.3, 2.4, 1.0), listOf(0.2, 2.6, 2.1, -1.0),
        listOf(2.5, 1.1, 0.0, 2.2), listOf(2.2, 2.3, -0.5, 0.7), listOf(1.0, 2.1, 2.7, 0.1),
        listOf(2.4, 0.4, 1.2, 2.3), listOf(2.6, 2.2, 1.5, -0.2), listOf(0.6, 2.5, 0.3, 2.1),
        listOf(2.1, 1.0, 2.2, 0.5), listOf(2.3, 2.4, 0.8, 1.1), listOf(1.2, 2.2, 2.5, 0.0),
        listOf(2.7, 0.1, 2.1, 1.3), listOf(2.2, 2.6, -0.3, 0.9), listOf(0.4, 2.3, 2.2, 1.0),
        // Single-noisy-signal nights.
        listOf(5.0, 0.5, -0.2, 1.0), listOf(0.3, 4.5, 1.1, -0.5), listOf(1.2, -1.0, 3.8, 0.4),
        listOf(0.7, 1.0, 0.2, 4.2), listOf(6.0, -0.5, 0.8, 1.2), listOf(1.5, 5.5, -0.3, 0.6),
        listOf(-0.4, 0.9, 4.9, 1.0), listOf(1.1, 0.2, 1.0, 5.1), listOf(3.2, 1.0, 1.5, 0.5),
        listOf(0.8, 3.5, 1.2, 1.0), listOf(1.0, 0.6, 3.1, 1.4), listOf(1.3, 1.0, 0.7, 3.6),
        listOf(4.7, 1.4, 1.0, 0.3), listOf(0.9, 4.0, 0.5, 1.1), listOf(1.0, 0.8, 4.4, 0.9),
        // Normal nights.
        listOf(0.5, -0.3, 1.2, 0.8), listOf(-1.0, 0.4, 0.6, 1.5), listOf(1.8, 1.0, -0.5, 0.2),
        listOf(0.0, 1.9, 1.1, -1.2), listOf(1.5, -0.8, 0.9, 1.0), listOf(-0.4, 1.2, 1.7, 0.3),
        listOf(1.1, 0.5, -0.2, 1.6), listOf(0.7, 1.8, 0.4, 0.9), listOf(-1.5, 0.6, 1.3, 1.0),
        listOf(1.0, 1.0, 1.0, 1.0), listOf(0.3, -0.5, 1.9, 0.7), listOf(1.6, 1.1, 0.2, -0.6),
        listOf(0.9, 1.7, 1.0, 1.2), listOf(-0.2, 0.8, 1.5, 1.8), listOf(1.4, 1.3, -1.0, 0.5),
    )
}
