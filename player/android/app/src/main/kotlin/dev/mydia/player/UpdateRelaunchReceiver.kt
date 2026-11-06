package dev.mydia.player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Reopens the app after it has updated itself.
 *
 * Installing a new build kills the running one, so without this an update
 * ends with the app simply gone. Android delivers MY_PACKAGE_REPLACED to the
 * new build once it is in place, and this starts MainActivity from it.
 *
 * Android 10+ may refuse an activity start from the background, and does so
 * without saying. So the receiver also posts a notification that opens the
 * app, before trying the start, and MainActivity clears that notification
 * when it comes up. Whichever way the user gets back, nothing is left behind.
 */
class UpdateRelaunchReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        // Every replacement lands here, including a Play Store auto-update
        // or an adb install. Only one this app started itself may open it.
        if (!consumeMarker(context)) return

        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ?: return

        postOpenNotification(context, launch)

        try {
            context.startActivity(launch)
        } catch (error: Exception) {
            Log.w(TAG, "Could not reopen after the update: ${error.message}")
        }
    }

    private fun postOpenNotification(context: Context, launch: Intent) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(CHANNEL_ID) == null
        ) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.update_channel_name),
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply { setShowBadge(false) }
            )
        }

        val tap = PendingIntent.getActivity(
            context,
            0,
            launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.update_installed_title))
            .setContentText(context.getString(R.string.update_installed_text))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build()

        try {
            manager.notify(NOTIFICATION_ID, notification)
        } catch (error: SecurityException) {
            // POST_NOTIFICATIONS not granted on Android 13+. The start below
            // is then the only way back, which is no worse than before.
            Log.w(TAG, "Could not post the reopen notification: ${error.message}")
        }
    }

    companion object {
        private const val TAG = "UpdateRelaunchReceiver"
        private const val CHANNEL_ID = "mydia_updates"
        private const val NOTIFICATION_ID = 300
        private const val PREFS = "mydia_update_relaunch"
        private const val KEY_STARTED_AT = "started_at"

        /**
         * How long a marker stays good. An install the user abandoned at
         * Android's dialog leaves one behind, and a stale marker must not
         * reopen the app on some unrelated update days later.
         */
        private const val MARKER_TTL_MS = 30 * 60 * 1000L

        /** Called by ApkInstaller just before it commits a session. */
        fun markStarted(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putLong(KEY_STARTED_AT, System.currentTimeMillis())
                .commit()
        }

        private fun consumeMarker(context: Context): Boolean {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val startedAt = prefs.getLong(KEY_STARTED_AT, 0L)
            prefs.edit().remove(KEY_STARTED_AT).commit()
            val age = System.currentTimeMillis() - startedAt
            return startedAt > 0L && age in 0..MARKER_TTL_MS
        }

        /** Clears the reopen notification once the app is back up. */
        fun clear(context: Context) {
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.cancel(NOTIFICATION_ID)
        }
    }
}
