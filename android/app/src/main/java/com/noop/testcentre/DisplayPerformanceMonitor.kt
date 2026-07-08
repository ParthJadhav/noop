package com.noop.testcentre

import android.content.Context
import android.content.res.Configuration
import android.os.Debug
import android.view.Choreographer
import com.noop.analytics.DisplayMetrics
import com.noop.analytics.DisplayTrace

/**
 * The app-layer frame-time / hitch / memory monitor for the Display & Performance test mode (Kotlin twin
 * of the Swift DisplayPerformanceMonitor).
 *
 * CRITICAL CONTRACT: this monitor is a PERFORMANCE tool that must not itself cost performance. It runs
 * ONLY while the Display mode is active. start() registers a Choreographer.FrameCallback when the mode
 * toggles on; stop() removes it when the mode toggles off. There is NO perpetual frame callback: when the
 * mode is off, no callback is posted, no frame fires, and zero DISPLAY lines are emitted. A test pins
 * exactly that (DisplayPerformanceMonitorTest).
 *
 * The frame callback samples each frame's duration, counts hitches over a threshold, and emits a ROLLING
 * SUMMARY line once per window of frames (not per frame), so the trace is bounded. Every emitted line
 * rides the caller's sink (vm.ble.externalLog(line, DISPLAY), the redacting log sink). Touches only the
 * main looper Choreographer + the sink, so it is exercised on the plain JVM for the pure pieces; the
 * Choreographer wiring is the only Android-only part and is never run in a test.
 */
object DisplayPerformanceMonitor {

    /** A frame is a "hitch" when its duration exceeds this (ms), matching the Swift threshold. */
    const val HITCH_THRESHOLD_MS: Double = 33.0

    /** Emit one rolling summary per this many frames (~1 s at 60 Hz), matching the Swift window. */
    const val WINDOW_FRAMES: Int = 60

    private var running = false
    private var sink: ((String) -> Unit)? = null

    /**
     * CAPTURE-D (#797): a provider of the on-device DATA VOLUME, wired by the Test Centre screen to
     * [com.noop.data.WhoopRepository.dataVolumeSnapshot]. When set, [emitDataVolume] emits ONE upfront
     * `dataVolume` line so an import-driven-lag report shows the read-set the screens render over, not only
     * frame stats. null leaves the line unemitted (e.g. a test with no store). Mirrors the Swift
     * DisplayPerformanceMonitor.dataVolumeProvider.
     */
    var dataVolumeProvider: (suspend () -> com.noop.analytics.DataVolume?)? = null

    private var lastFrameNanos: Long = 0
    private val windowDurationsMs = ArrayList<Double>()
    private var windowHitches = 0
    private var windowWorstMs = 0.0
    private var memoryPeakMB = 0.0

    /** True only while the frame callback is registered. The test asserts this is false when off. */
    val isRunning: Boolean get() = running

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!running) return
            foldFrame(frameTimeNanos)
            // Re-post for the next frame ONLY while running, so removing the callback on stop() ends the
            // chain immediately (there is no standing registration to leak).
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    // Lifecycle (the ONLY place the frame callback is posted / removed) -------------------------------

    /**
     * Start the monitor: emit the device metrics immediately, sample memory, and begin the frame chain.
     * Idempotent. [context] reads the live Configuration for the metrics line; [emit] is the redacting
     * DISPLAY sink.
     */
    fun start(context: Context, emit: (String) -> Unit) {
        if (running) return
        running = true
        sink = emit
        resetWindow()
        lastFrameNanos = 0
        memoryPeakMB = 0.0
        sampleMemory()
        emit(DisplayTrace.deviceMetricsLine(readMetrics(context)))
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    /**
     * CAPTURE-D (#797): read the on-device DATA VOLUME (via [dataVolumeProvider]) and emit ONE upfront
     * `dataVolume` line. Suspend because the read hits the store; the Test Centre screen calls it once from
     * a coroutine right after [start] (the monitor object itself owns no scope, mirroring how the Swift
     * monitor emits it in a Task wired by TestCentreView). A no-op when the monitor is off, the sink is
     * gone, or no provider is set. A null snapshot emits nothing (never a fabricated zero line).
     */
    suspend fun emitDataVolume() {
        if (!running) return
        val provider = dataVolumeProvider ?: return
        val volume = runCatching { provider() }.getOrNull() ?: return
        sink?.invoke(DisplayTrace.dataVolumeLine(volume))
    }

    /**
     * Stop the monitor: remove the frame callback (so nothing keeps firing), flush a final partial window
     * if it holds samples, and emit the memory high-water. After this no frame fires and no DISPLAY line is
     * emitted until the next start(). Idempotent.
     */
    fun stop() {
        if (!running) return
        running = false
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        flushWindow()
        sink?.invoke(DisplayTrace.memoryHighWaterLine(memoryPeakMB))
        sink = null
    }

    // Frame sampling ---------------------------------------------------------------------------------

    private fun foldFrame(frameTimeNanos: Long) {
        val prev = lastFrameNanos
        lastFrameNanos = frameTimeNanos
        if (prev <= 0L) return // seed frame, no duration yet
        val durationMs = (frameTimeNanos - prev) / 1_000_000.0
        if (durationMs <= 0 || durationMs >= 5_000) return // ignore a backgrounding gap
        windowDurationsMs.add(durationMs)
        if (durationMs > HITCH_THRESHOLD_MS) windowHitches++
        if (durationMs > windowWorstMs) windowWorstMs = durationMs
        if (windowDurationsMs.size >= WINDOW_FRAMES) {
            sampleMemory()
            flushWindow()
        }
    }

    private fun flushWindow() {
        if (windowDurationsMs.isEmpty()) return
        val stats = windowStats(windowDurationsMs)
        sink?.invoke(
            DisplayTrace.frameSummaryLine(
                frames = windowDurationsMs.size,
                meanMs = stats.first, p95Ms = stats.second,
                hitches = windowHitches, worstMs = windowWorstMs,
                hitchThresholdMs = HITCH_THRESHOLD_MS,
            ),
        )
        resetWindow()
    }

    private fun resetWindow() {
        windowDurationsMs.clear()
        windowHitches = 0
        windowWorstMs = 0.0
    }

    /** Pure window stats: mean and p95 (nearest-rank) of the frame durations. Static and side-effect-free
     *  so a fixture can pin the exact summary numbers without a live frame callback. Mirrors the Swift
     *  windowStats. */
    fun windowStats(durationsMs: List<Double>): Pair<Double, Double> {
        if (durationsMs.isEmpty()) return 0.0 to 0.0
        val mean = durationsMs.sum() / durationsMs.size
        val sorted = durationsMs.sorted()
        // Nearest-rank p95 as a 0-based index: idx = ceil(0.95 * n), clamped to the last element. This
        // counts the values that fall BELOW the percentile, so at least 95% of frames are at or below the
        // returned value. For a hitch trace that matters: a window of 20 frames with one 5%-tail hitch
        // lands p95 ON the hitch (idx = ceil(0.95 * 20) = 19 = the worst of 20). Mirrors the Swift twin.
        val idx = Math.ceil(0.95 * sorted.size).toInt()
        val p95 = sorted[minOf(idx, sorted.size - 1)]
        return mean to p95
    }

    // Memory high-water ------------------------------------------------------------------------------

    private fun sampleMemory() {
        val mb = residentFootprintMB()
        if (mb > memoryPeakMB) memoryPeakMB = mb
    }

    /** Current resident footprint in MB via Debug total PSS (the "real memory" figure for the process).
     *  Kotlin twin of the Swift phys_footprint read. */
    private fun residentFootprintMB(): Double {
        val mi = Debug.MemoryInfo()
        Debug.getMemoryInfo(mi)
        return mi.totalPss / 1024.0 // totalPss is in KB
    }

    // Device metrics (read live, formatted by the pure DisplayTrace) ---------------------------------

    /** Read the current display environment into the pure DisplayMetrics carrier from the Android
     *  Configuration. Android has no true size class, so those are null (printed "n/a"); fontScale becomes
     *  the dynamicType label; densityDpi gives the backing scale; uiMode-night gives the theme. */
    fun readMetrics(context: Context): DisplayMetrics {
        val cfg: Configuration = context.resources.configuration
        val density = context.resources.displayMetrics.density.toDouble()
        val nightMode = cfg.uiMode and Configuration.UI_MODE_NIGHT_MASK
        val dark = nightMode == Configuration.UI_MODE_NIGHT_YES
        val portrait = cfg.orientation != Configuration.ORIENTATION_LANDSCAPE
        return DisplayMetrics(
            horizontalSizeClass = null, verticalSizeClass = null, // Android has no size class
            widthPt = cfg.screenWidthDp.toDouble(), heightPt = cfg.screenHeightDp.toDouble(),
            scale = density,
            safeTop = 0.0, safeBottom = 0.0, safeLeading = 0.0, safeTrailing = 0.0,
            dynamicType = fontScaleLabel(cfg.fontScale),
            orientation = if (portrait) "portrait" else "landscape",
            theme = if (dark) "dark" else "light",
        )
    }

    /** The Android Dynamic Type label is the font scale to two decimals ("1.00" / "1.30" / "1.50"), so a
     *  "text is clipped" report shows how large the user's text was. */
    internal fun fontScaleLabel(scale: Float): String = String.format(java.util.Locale.US, "%.2f", scale)
}
