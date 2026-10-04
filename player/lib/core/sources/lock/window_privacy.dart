/// Keeps an open locked or hidden source out of screenshots and the app
/// switcher: Android's FLAG_SECURE, an iOS blur while inactive. Desktop
/// switchers show live windows, so there is nothing to do there.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowPrivacy {
  static const _channel = MethodChannel('dev.mydia.player/privacy');

  static Future<void> setSecure(bool secure) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _channel.invokeMethod<void>('setSecure', {'secure': secure});
    } catch (e) {
      debugPrint('[SourceLock] window privacy unavailable: $e');
    }
  }
}
