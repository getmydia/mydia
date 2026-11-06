package dev.mydia.player

import android.app.Activity
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import java.io.File

/**
 * Installs a downloaded APK through PackageInstaller.
 *
 * PackageInstaller rather than an ACTION_VIEW intent on a FileProvider URI:
 * the session API reports its own failures, needs no provider declaration,
 * and is the path Android has kept working across versions. Any confirmation
 * dialog is the system's; on Android 12+ it skips that dialog for an app
 * updating itself, which is what makes the update one press.
 */
class ApkInstaller(private val activity: Activity) {

    /** Whether the user has allowed this app to install packages. */
    fun canInstall(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return activity.packageManager.canRequestPackageInstalls()
    }

    /** Opens the system screen where that permission is granted. */
    fun requestPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:${activity.packageName}")
        )
        activity.startActivity(intent)
    }

    /**
     * Streams [path] into a session and commits it.
     *
     * Returns once the session has been committed, not once the user has
     * approved it. Committing only hands the session to the OS; the
     * confirmation dialog and the actual install happen afterwards, on the
     * OS's own schedule, and are reported to [ApkInstallReceiver] rather than
     * back through this call.
     *
     * Throws IllegalStateException with a message the Dart side surfaces to
     * the user. The session is abandoned on any failure, whether it happens
     * while opening the session or afterwards, so a half-written or unopened
     * one cannot accumulate.
     */
    fun install(path: String) {
        val apk = File(path)
        if (!apk.exists()) throw IllegalStateException("The downloaded file is missing.")

        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL
        )
        params.setAppPackageName(activity.packageName)
        // Android 12+ skips its confirmation dialog for an app updating
        // itself, provided this app is already the package's installer of
        // record (it installed the running copy) and holds
        // UPDATE_PACKAGES_WITHOUT_USER_ACTION. When either is not so, as on
        // the first update after a sideload from a browser, the session
        // falls back to STATUS_PENDING_USER_ACTION and ApkInstallReceiver
        // shows the dialog as before. Committing through this app also makes
        // it the installer of record, so only that first update asks.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(
                PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED
            )
        }

        val sessionId = installer.createSession(params)
        var opened: PackageInstaller.Session? = null

        try {
            val session = installer.openSession(sessionId)
            opened = session

            session.openWrite("mydia-update", 0, apk.length()).use { output ->
                apk.inputStream().use { input -> input.copyTo(output) }
                session.fsync(output)
            }

            val intent = Intent(activity, ApkInstallReceiver::class.java)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
            val pending = PendingIntent.getBroadcast(activity, sessionId, intent, flags)
            // Committed synchronously before the session, which can replace
            // this process the moment it is committed.
            UpdateRelaunchReceiver.markStarted(activity)
            session.commit(pending.intentSender)
        } catch (error: Exception) {
            opened?.abandon() ?: installer.abandonSession(sessionId)
            throw IllegalStateException(error.message ?: "The install session failed.")
        } finally {
            opened?.close()
        }
    }
}
