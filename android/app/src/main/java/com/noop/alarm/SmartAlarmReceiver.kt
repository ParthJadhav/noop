package com.noop.alarm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import com.noop.R
import com.noop.ui.appLaunchIntent

/**
 * Fires when the guaranteed wake alarm goes off (scheduled by [SmartAlarmScheduler] via AlarmManager).
 *
 * Raises a FULL-SCREEN, high-priority, alarm-category notification with the device alarm sound and a
 * vibration pattern — the standard way a sideloaded app delivers a dependable wake without owning a
 * foreground Activity. The full-screen intent re-opens NOOP; on a locked screen the system promotes
 * the notification to a heads-up / full-screen alarm. This path is reached whether the alarm fired at
 * the smart (light-sleep) time or the hard deadline, so the user is woken either way.
 *
 * Registered in the manifest (exported=false) so it survives the app being killed. After firing it
 * clears the persisted schedule (a one-shot alarm), then re-arms the strap-independent fallback for
 * the NEXT day only when the watcher / app re-arms it — we do not silently re-schedule here, so a
 * disabled-then-fired alarm doesn't resurrect itself.
 */
class SmartAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != SmartAlarmScheduler.ACTION_FIRE) return
        val smart = intent.getBooleanExtra(SmartAlarmScheduler.EXTRA_SMART, false)

        // Clear the schedule we just fired so a boot right after firing doesn't re-raise THIS one...
        val store = SmartAlarmStore.from(context)
        store.scheduledDeadlineMs = 0L
        store.scheduledWindowStartMs = 0L
        // ...then, if the alarm is still enabled, re-arm the GUARANTEED deadline for the NEXT day so
        // the smart alarm recurs each morning. arm() computes the next occurrence (tomorrow, since
        // today's just passed). A disabled-but-fired alarm does NOT resurrect itself.
        runCatching { if (store.enabled) SmartAlarmScheduler.arm(context, store) }

        ensureChannel(context)
        // Defensive: a notify() throw (OEM quirk / revoked POST_NOTIFICATIONS) must not crash the
        // broadcast. The system alarm sound below is the fallback-of-the-fallback audible cue.
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            mgr.notify(NOTIF_ID, buildNotification(context, smart))
        }
    }

    private fun buildNotification(context: Context, smart: Boolean): Notification {
        val fullScreen = PendingIntent.getActivity(
            context, 0, appLaunchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val title = "Good morning"
        val body = if (smart) {
            "You're in a lighter sleep phase. Time to wake up."
        } else {
            "Your wake window has ended. Time to get up."
        }
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(fullScreen)
            .setFullScreenIntent(fullScreen, true)   // promote to a full-screen alarm on a locked phone
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setOngoing(true)
            .build()
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            val alarmSound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Smart alarm",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "The phone wake alarm NOOP fires inside your chosen wake window."
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 600, 400, 600, 400, 600)
                setBypassDnd(true)   // a wake alarm should sound through Do Not Disturb
                if (alarmSound != null) {
                    setSound(
                        alarmSound,
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                }
            }
            mgr.createNotificationChannel(channel)
        }
    }

    companion object {
        const val CHANNEL_ID = "noop_smart_alarm"
        private const val NOTIF_ID = 4307
    }
}
