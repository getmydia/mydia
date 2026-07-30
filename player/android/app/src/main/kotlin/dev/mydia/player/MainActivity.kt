package dev.mydia.player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "dev.mydia.player/notifications"
    private val multicastChannelName = "dev.mydia.player/multicast"

    /**
     * Held only while cast discovery is running.
     *
     * Android's Wi-Fi stack filters out multicast/broadcast packets that are
     * not addressed to this device unless a multicast lock is held, which
     * silently starves both SSDP (DLNA) and mDNS (Chromecast) discovery. The
     * lock is reference counted so nested acquires are safe, and it is
     * released in onDestroy so a crash mid-discovery cannot pin the radio in
     * its higher-power mode.
     */
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, multicastChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        acquireMulticastLock()
                        result.success(null)
                    }
                    "releaseMulticastLock" -> {
                        releaseMulticastLock()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateProgress" -> {
                        val notificationId = call.argument<Int>("notificationId") ?: 200
                        val title = call.argument<String>("title") ?: ""
                        val text = call.argument<String>("text") ?: ""
                        val progress = call.argument<Int>("progress") ?: 0
                        val maxProgress = call.argument<Int>("maxProgress") ?: 100
                        val indeterminate = call.argument<Boolean>("indeterminate") ?: false

                        updateProgressNotification(
                            notificationId, title, text,
                            progress, maxProgress, indeterminate
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun acquireMulticastLock() {
        val existing = multicastLock
        if (existing != null) {
            existing.acquire()
            return
        }

        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifi.createMulticastLock("mydia-cast-discovery").apply {
            setReferenceCounted(true)
            acquire()
        }
        multicastLock = lock
    }

    private fun releaseMulticastLock() {
        val lock = multicastLock ?: return
        if (lock.isHeld) {
            lock.release()
        }
        if (!lock.isHeld) {
            multicastLock = null
        }
    }

    override fun onDestroy() {
        val lock = multicastLock
        while (lock != null && lock.isHeld) {
            lock.release()
        }
        multicastLock = null
        super.onDestroy()
    }

    private fun updateProgressNotification(
        notificationId: Int,
        title: String,
        text: String,
        progress: Int,
        maxProgress: Int,
        indeterminate: Boolean
    ) {
        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val channelId = "mydia_downloads"

        // Ensure channel exists (required for Android O+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val existing = notificationManager.getNotificationChannel(channelId)
            if (existing == null) {
                val channel = NotificationChannel(
                    channelId,
                    "Downloads",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Shows progress while downloading media files."
                    enableVibration(false)
                    setSound(null, null)
                    setShowBadge(false)
                }
                notificationManager.createNotificationChannel(channel)
            }
        }

        val notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setSilent(true)
            .setProgress(maxProgress, progress, indeterminate)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        notificationManager.notify(notificationId, notification)
    }
}
