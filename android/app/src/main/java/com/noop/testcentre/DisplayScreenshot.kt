package com.noop.testcentre

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.graphics.Canvas
import java.io.ByteArrayOutputStream

/**
 * Captures the current screen as PNG bytes for the Display & Performance test mode's export bundle
 * (Kotlin twin of the Swift DisplayScreenshot).
 *
 * The PNG is BINARY image bytes, not a text line, so it is NOT run through the strap-log PII scrub (that
 * is correct: redaction scrubs text identifiers, not pixels). The screenshot IS covered by the mandatory
 * review-before-share gate: the report never ships until the user taps Share, and the gate names the
 * attachment. A capture only ever happens for the DISPLAY profile, gated by the screen behind
 * testCentre.active(DISPLAY), so a non-display report never grabs a shot.
 */
object DisplayScreenshot {

    /** The in-zip name of the captured screenshot, matching the Swift bundle name. */
    const val BUNDLE_NAME = "screenshot.png"

    /**
     * Capture the current Activity's decor view as PNG bytes, or null if there is no Activity / the draw
     * failed. Called on the main thread (the Report button tap path), so it can draw the view directly.
     * Drawing the decor view into a software Bitmap shows exactly what is on screen (including the
     * possibly-broken frame the user is reporting), with no async PixelCopy round-trip.
     */
    fun capturePNG(context: Context): ByteArray? = runCatching {
        val activity = context.findActivity() ?: return null
        val view = activity.window?.decorView ?: return null
        val w = view.width
        val h = view.height
        if (w <= 0 || h <= 0) return null
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        out.toByteArray()
    }.getOrNull()

    /** Walk the ContextWrapper chain to the hosting Activity, or null (e.g. an application context). */
    private fun Context.findActivity(): Activity? {
        var ctx: Context? = this
        while (ctx is ContextWrapper) {
            if (ctx is Activity) return ctx
            ctx = ctx.baseContext
        }
        return null
    }
}
