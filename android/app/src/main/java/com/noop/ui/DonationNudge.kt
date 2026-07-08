package com.noop.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

// Donation nudge (Today screen) — mirror of macOS/iOS `DonationNudgeCard`.
//
// A small, dismissible card that asks — at most once every 12 hours — whether NOOP is
// proving useful, and makes the honest economic case for a donation: a WHOOP membership
// costs $300–480 a year, NOOP is free and built by one person, and almost nobody donates.
//
// Deliberately a CARD in the Today flow, not a dialog: never blocks anything, never
// interrupts, and carries a permanent opt-out. The stats line is baked in at release time
// (see [DonationStats]) so the app stays fully offline — no network calls, ever.

/** Release-time-stamped community stats. Refresh with Tools/update-donation-stats.sh before
 *  each release (the app itself NEVER touches the network). Keep in lockstep with the Swift
 *  `DonationStats`. */
object DonationStats {
    const val DOWNLOADS = 8_500
    const val DONORS = 12
    const val DONATE_URL = "https://github.com/NoopApp/noop/wiki/Donations"
}

/** Plain-prefs persistence for the nudge cadence (12 h) + permanent opt-out. */
object DonationNudgePrefs {
    private const val FILE = "noop_donate_prefs"
    private const val KEY_LAST_SHOWN = "donate.lastShownTs"
    private const val KEY_OPT_OUT = "donate.optOut"
    private const val WINDOW_MS = 12 * 3_600_000L

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** Whether the card should render now; arms the 12 h timer on first sight so a fresh
     *  install gets its first nudge after 12 h of real use, not on first launch. */
    fun shouldShow(ctx: Context): Boolean {
        val p = prefs(ctx)
        if (p.getBoolean(KEY_OPT_OUT, false)) return false
        val last = p.getLong(KEY_LAST_SHOWN, 0L)
        val now = System.currentTimeMillis()
        if (last == 0L) {
            p.edit().putLong(KEY_LAST_SHOWN, now).apply()
            return false
        }
        return now - last >= WINDOW_MS
    }

    fun stamp(ctx: Context) =
        prefs(ctx).edit().putLong(KEY_LAST_SHOWN, System.currentTimeMillis()).apply()

    fun optOut(ctx: Context) =
        prefs(ctx).edit().putBoolean(KEY_OPT_OUT, true).apply()
}

@Composable
fun DonationNudgeCard() {
    val context = LocalContext.current
    var visible by remember { mutableStateOf(DonationNudgePrefs.shouldShow(context)) }
    if (!visible) return

    // A frosted, brand-green-tinted card — the Charge world's anchor colour — so the honest
    // donation ask reads as a warm, on-brand moment, never a hard grey box.
    NoopCard(tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Filled.Favorite, contentDescription = null,
                    tint = Palette.accent, modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.size(8.dp))
                Text("Enjoying NOOP?", style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                "A WHOOP membership runs $300-480 a year, for life. NOOP does this for free - " +
                    "one person, no servers, no subscription.",
                style = NoopType.footnote, color = Palette.textSecondary,
            )
            Text(
                "If it's saving you a subscription, a suggested \$50+ - a fraction of a year of WHOOP - " +
                    "genuinely keeps the project alive. Anything is appreciated. Crypto only; the project stays anonymous.",
                style = NoopType.footnote, color = Palette.textSecondary,
            )
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Button(
                    onClick = {
                        DonationNudgePrefs.stamp(context)
                        visible = false
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(DonationStats.DONATE_URL)))
                    },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                    ),
                ) { Text("Donate") }
                Spacer(Modifier.size(10.dp))
                TextButton(onClick = {
                    DonationNudgePrefs.stamp(context)
                    visible = false
                }) { Text("Later", color = Palette.textSecondary) }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = {
                    DonationNudgePrefs.optOut(context)
                    visible = false
                }) { Text("Don't ask again", color = Palette.textTertiary, style = NoopType.footnote) }
            }
        }
    }
}
