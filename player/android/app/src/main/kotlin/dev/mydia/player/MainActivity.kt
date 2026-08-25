package dev.mydia.player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.net.wifi.WifiManager
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "dev.mydia.player/notifications"
    private val multicastChannelName = "dev.mydia.player/multicast"
    private val codecChannelName = "dev.mydia.player/codecs"

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, codecChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "videoDecoderCapabilities" -> result.success(videoDecoderCapabilities())
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

    /**
     * What this device's video decoders can actually open.
     *
     * libmpv's `decoder-list`, which the player probes for its device profile,
     * reports what libavcodec was *compiled* with. It says "hevc" on a tablet
     * whose MediaCodec decoder opens HEVC Main and refuses Main 10, so the
     * server direct-plays a 10-bit stream and playback dies on "Could not open
     * codec." with no recoverable path. This asks the platform the question
     * that actually matters.
     *
     * Only decoders are considered, and a codec is reported only if some
     * decoder claims its MIME type. Anything that throws is skipped rather than
     * failing the whole probe: a single vendor codec with a broken capability
     * table must not cost the device its entire profile.
     */
    private fun videoDecoderCapabilities(): List<Map<String, Any>> {
        val best = mutableMapOf<String, MutableMap<String, Any>>()

        val infos = try {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
        } catch (error: Exception) {
            return emptyList()
        }

        for (info in infos) {
            if (info.isEncoder) continue

            for (mime in info.supportedTypes) {
                val codec = codecNameFor(mime.lowercase()) ?: continue

                try {
                    val capabilities = info.getCapabilitiesForType(mime)
                    val video = capabilities.videoCapabilities ?: continue

                    val depth = maxBitDepthFor(mime.lowercase(), capabilities.profileLevels)
                    val width = video.supportedWidths.upper
                    val height = video.supportedHeights.upper

                    val entry = best.getOrPut(codec) {
                        mutableMapOf(
                            "codec" to codec,
                            "maxBitDepth" to 8,
                            "maxWidth" to 0,
                            "maxHeight" to 0
                        )
                    }

                    entry["maxBitDepth"] = maxOf(entry["maxBitDepth"] as Int, depth)
                    entry["maxWidth"] = maxOf(entry["maxWidth"] as Int, width)
                    entry["maxHeight"] = maxOf(entry["maxHeight"] as Int, height)
                } catch (error: Exception) {
                    continue
                }
            }
        }

        return best.values.map { it.toMap() }
    }

    private fun codecNameFor(mime: String): String? = when (mime) {
        "video/avc" -> "h264"
        "video/hevc" -> "hevc"
        "video/x-vnd.on2.vp8" -> "vp8"
        "video/x-vnd.on2.vp9" -> "vp9"
        "video/av01" -> "av1"
        "video/mp4v-es" -> "mpeg4"
        "video/mpeg2" -> "mpeg2"
        else -> null
    }

    /**
     * The deepest bit depth any advertised profile for [mime] implies.
     *
     * Defaults to 8 rather than to "unknown": a decoder that lists no profile
     * this build recognizes is treated as 8-bit only, which is the direction
     * that asks the server to transcode instead of handing over a stream the
     * device may not open.
     */
    private fun maxBitDepthFor(mime: String, profiles: Array<MediaCodecInfo.CodecProfileLevel>): Int {
        var depth = 8

        for (level in profiles) {
            val candidate = when (mime) {
                "video/hevc" -> when (level.profile) {
                    MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10,
                    MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10,
                    MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10Plus -> 10
                    else -> 8
                }
                "video/avc" -> when (level.profile) {
                    MediaCodecInfo.CodecProfileLevel.AVCProfileHigh10 -> 10
                    else -> 8
                }
                "video/x-vnd.on2.vp9" -> when (level.profile) {
                    MediaCodecInfo.CodecProfileLevel.VP9Profile2,
                    MediaCodecInfo.CodecProfileLevel.VP9Profile3,
                    MediaCodecInfo.CodecProfileLevel.VP9Profile2HDR,
                    MediaCodecInfo.CodecProfileLevel.VP9Profile3HDR -> 10
                    else -> 8
                }
                "video/av01" -> when (level.profile) {
                    MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10,
                    MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10HDR10,
                    MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10HDR10Plus -> 10
                    else -> 8
                }
                else -> 8
            }

            if (candidate > depth) depth = candidate
        }

        return depth
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
