import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Holds Android's `WifiManager.MulticastLock` for the duration of discovery.
///
/// Android drops multicast and broadcast packets that are not addressed to the
/// device unless an app explicitly asks for them. SSDP (DLNA) and mDNS
/// (Chromecast) are both multicast, so without this lock discovery quietly
/// finds nothing on most phones — the `CHANGE_WIFI_MULTICAST_STATE` permission
/// on its own does nothing but make the lock *available*.
///
/// The lock costs battery, which is why it is scoped to a discovery sweep
/// rather than the app's lifetime.
class MulticastLock {
  static const defaultChannel = MethodChannel('dev.mydia.player/multicast');

  final MethodChannel _channel;

  const MulticastLock({MethodChannel channel = defaultChannel})
      : _channel = channel;

  /// Only Android has (or needs) this concept. Everywhere else both calls are
  /// no-ops, so callers do not have to platform-branch.
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> acquire() => _invoke('acquireMulticastLock');

  Future<void> release() => _invoke('releaseMulticastLock');

  Future<void> _invoke(String method) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>(method);
    } catch (e) {
      // A missing lock degrades discovery; it must never break the picker.
      debugPrint('[MulticastLock] $method failed: $e');
    }
  }
}
