package dev.mydia.player

import android.app.Activity
import android.content.Context
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
 * and is the path Android has kept working across versions. The confirmation
 * dialog is still the system's, so nothing here can install silently.
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
     * Throws IllegalStateException with a message the Dart side surfaces to
     * the user. The session is abandoned on any failure so a half-written one
     * cannot accumulate.
     */
    fun install(path: String) {
        val apk = File(path)
        if (!apk.exists()) throw IllegalStateException("The downloaded file is missing.")

        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL
        )
        params.setAppPackageName(activity.packageName)

        val sessionId = installer.createSession(params)
        val session = installer.openSession(sessionId)

        try {
            session.openWrite("mydia-update", 0, apk.length()).use { output ->
                apk.inputStream().use { input -> input.copyTo(output) }
                session.fsync(output)
            }

            val intent = Intent(activity, MainActivity::class.java)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                android.app.PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
            val pending = android.app.PendingIntent.getActivity(
                activity, sessionId, intent, flags
            )
            session.commit(pending.intentSender)
        } catch (error: Exception) {
            session.abandon()
            throw IllegalStateException(error.message ?: "The install session failed.")
        } finally {
            session.close()
        }
    }
}
