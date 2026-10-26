/// Foreground service for keeping the app alive during downloads on Android.
///
/// Wraps flutter_foreground_task to show a persistent notification while
/// downloads are active. Uses a native platform channel to display a
/// progress bar in the notification.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../l10n/l10n.dart';

/// Top-level callback required by flutter_foreground_task.
/// Must be a top-level or static function.
@pragma('vm:entry-point')
void _downloadTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_NoOpTaskHandler());
}

/// No-op task handler - all download work happens in the main isolate.
/// This handler exists only to satisfy the flutter_foreground_task API.
class _NoOpTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Notification icon metadata name matching AndroidManifest.xml meta-data.
const _notificationIconMetaData = 'dev.mydia.player.NOTIFICATION_ICON';

/// Platform channel for native notification updates with progress bar.
const _channel = MethodChannel('dev.mydia.player/notifications');

/// Service that manages an Android foreground service notification
/// to keep the app process alive during downloads.
///
/// On non-Android platforms, all methods are no-ops.
class DownloadNotificationService {
  static final DownloadNotificationService _instance =
      DownloadNotificationService._();
  static DownloadNotificationService get instance => _instance;

  DownloadNotificationService._();

  bool _initialized = false;
  bool _permissionDenied = false;

  /// The service/notification ID used by the foreground service.
  static const notificationId = 200;

  /// Initialize the foreground task configuration.
  /// Call once at app startup (e.g., from download service init).
  void initialize() {
    if (!Platform.isAndroid || _initialized) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'mydia_downloads',
        // Android keeps the channel's name and description from the first
        // time it is created, so they follow the language of that moment.
        channelName: currentAppLocalizations().navDownloads,
        channelDescription:
            currentAppLocalizations().downloadNotificationChannelDescription,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
        showWhen: false,
        enableVibration: false,
        playSound: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // We don't need repeat events - notification is updated manually
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );

    _initialized = true;
  }

  /// Request notification permission (Android 13+).
  /// Returns true if permission is granted.
  Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) return true;
    if (_permissionDenied) return false;

    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission == NotificationPermission.granted) return true;

    try {
      await FlutterForegroundTask.requestNotificationPermission();
      final result = await FlutterForegroundTask.checkNotificationPermission();
      if (result != NotificationPermission.granted) {
        _permissionDenied = true;
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[DownloadNotification] Permission request failed: $e');
      _permissionDenied = true;
      return false;
    }
  }

  /// Start the foreground service with an initial notification.
  Future<void> startService({
    required String title,
    required String text,
    int progress = 0,
    bool indeterminate = false,
  }) async {
    if (!Platform.isAndroid) return;
    if (!_initialized) initialize();

    if (await FlutterForegroundTask.isRunningService) {
      // Service already running, just update notification
      await updateNotification(
        title: title,
        text: text,
        progress: progress,
        indeterminate: indeterminate,
      );
      return;
    }

    await FlutterForegroundTask.startService(
      serviceId: notificationId,
      notificationTitle: title,
      notificationText: text,
      notificationIcon: const NotificationIcon(
        metaDataName: _notificationIconMetaData,
      ),
      callback: _downloadTaskCallback,
    );

    debugPrint('[DownloadNotification] Foreground service started');

    // Immediately replace with our custom progress notification
    await _updateNativeNotification(
      title: title,
      text: text,
      progress: progress,
      indeterminate: indeterminate,
    );
  }

  /// Update the notification with progress bar while the service is running.
  Future<void> updateNotification({
    required String title,
    required String text,
    int progress = 0,
    bool indeterminate = false,
  }) async {
    if (!Platform.isAndroid) return;

    if (!await FlutterForegroundTask.isRunningService) return;

    await _updateNativeNotification(
      title: title,
      text: text,
      progress: progress,
      indeterminate: indeterminate,
    );
  }

  /// Update the notification via the native platform channel.
  /// This replaces the foreground service notification with one that
  /// has a progress bar and the Mydia icon.
  Future<void> _updateNativeNotification({
    required String title,
    required String text,
    required int progress,
    required bool indeterminate,
  }) async {
    try {
      await _channel.invokeMethod('updateProgress', {
        'notificationId': notificationId,
        'title': title,
        'text': text,
        'progress': progress,
        'maxProgress': 100,
        'indeterminate': indeterminate,
      });
    } catch (e) {
      // Fall back to flutter_foreground_task's default update
      debugPrint(
          '[DownloadNotification] Native update failed, using fallback: $e');
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    }
  }

  /// Stop the foreground service and dismiss the notification.
  Future<void> stopService() async {
    if (!Platform.isAndroid) return;

    if (!await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.stopService();
    debugPrint('[DownloadNotification] Foreground service stopped');
  }
}
