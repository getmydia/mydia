/// Native traffic-light control, backed by a custom `MethodChannel` to
/// `AppDelegate.swift`.
///
/// Nothing here is allowed to throw — this runs as a side effect of
/// [ChromeVisibility]'s show/hide, never awaited, so a failure must be
/// caught and logged rather than surface as a red screen mid-playback.
/// Mirrors `desktop_window_native.dart`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'window_buttons_hidden.dart';
import 'window_chrome_channel.dart';
import 'window_fullscreen.dart';

const MethodChannel _channel = MethodChannel(kWindowChromeChannelName);

/// Whether [setWindowButtonsHidden] should forward a call for the given
/// [hidden] direction to the NATIVE buttons.
///
/// False off macOS regardless of [hidden]. Windows has no Flutter-drawn
/// chrome yet, and Linux draws its own buttons in Dart, so on Linux the
/// signal alone does the work and there is no native call to make.
/// On macOS, a hide (`hidden: true`) is additionally blocked
/// while [isFullscreen]: the OS already hides the buttons there on its own,
/// so forcing them hidden ourselves would fight its own transition. A
/// restore (`hidden: false`) is never blocked by fullscreen — `isHidden =
/// false` is the stock state every unmodified macOS app has there, so
/// passing a restore through is always safe. That asymmetry matters:
/// [ChromeVisibility]'s `dispose()` safety net calls this with `hidden:
/// false` unconditionally, and it must actually reach the native side even
/// when the player is torn down while still fullscreen — otherwise a window
/// could be left with its close/minimize/zoom buttons stranded hidden after
/// returning to windowed mode.
@visibleForTesting
bool shouldCallNativeButtonBridge({
  required TargetPlatform platform,
  required bool hidden,
  required bool isFullscreen,
}) =>
    platform == TargetPlatform.macOS && !(hidden && isFullscreen);

/// Hides or shows the window's close/minimize/maximize buttons.
///
/// Writes the app-wide signal on every platform, which is what the
/// Flutter-drawn Linux buttons watch, and additionally forwards to the native
/// AppKit buttons on macOS.
///
/// Fire-and-forget: callers do not await this, so any failure is caught and
/// logged here rather than propagating.
void setWindowButtonsHidden(bool hidden) {
  windowButtonsHiddenSignal.value = hidden;

  if (!shouldCallNativeButtonBridge(
    platform: defaultTargetPlatform,
    hidden: hidden,
    isFullscreen: windowFullscreen.value,
  )) {
    return;
  }

  try {
    unawaited(
      _channel.invokeMethod<void>(
          'setTrafficLightsHidden', {'hidden': hidden}).catchError(
        (Object e) => debugPrint(
          '[WindowButtons] Failed to toggle the native buttons: $e',
        ),
      ),
    );
  } catch (e) {
    debugPrint('[WindowButtons] Failed to toggle the native buttons: $e');
  }
}
