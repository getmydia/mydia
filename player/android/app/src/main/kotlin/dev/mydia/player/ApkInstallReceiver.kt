package dev.mydia.player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log

/**
 * Receives the outcome of a session committed by [ApkInstaller].
 *
 * Committing a session only starts it; the OS reports back here rather than
 * to the caller. A pending status means the confirmation dialog has not been
 * shown yet, and this receiver has to launch the intent the OS supplies to
 * show it, adding `FLAG_ACTIVITY_NEW_TASK` since a receiver has no activity
 * context of its own. Success needs nothing further. A failure is logged
 * with the OS's own status message so it is diagnosable rather than silent;
 * the user already left the app by the time it happens, so there is no
 * screen left here to show it on.
 */
class ApkInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE
        )

        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirmation = confirmationIntent(intent) ?: return
                confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(confirmation)
            }
            PackageInstaller.STATUS_SUCCESS -> {
                Log.i(TAG, "Update installed.")
            }
            else -> {
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                Log.e(TAG, "Install failed (status $status): $message")
            }
        }
    }

    private fun confirmationIntent(intent: Intent): Intent? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_INTENT)
        }
    }

    companion object {
        private const val TAG = "ApkInstallReceiver"
    }
}
