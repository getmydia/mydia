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

import 'window_fullscreen.dart';

const MethodChannel _channel = MethodChannel('dev.mydia.player/window_chrome');

/// Whether [setTrafficLightsHidden] should forward a call for the given
/// [hidden] direction to the native buttons.
///
/// False off macOS regardless of [hidden] — there are no traffic lights to
/// control there. On macOS, a hide (`hidden: true`) is additionally blocked
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
bool shouldControlTrafficLights({
  required TargetPlatform platform,
  required bool hidden,
  required bool isFullscreen,
}) =>
    platform == TargetPlatform.macOS && !(hidden && isFullscreen);

/// Hides or shows the native close/minimize/zoom buttons.
///
/// Fire-and-forget: callers do not await this, so any failure is caught and
/// logged here rather than propagating.
void setTrafficLightsHidden(bool hidden) {
  if (!shouldControlTrafficLights(
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
          '[TrafficLights] Failed to toggle traffic lights: $e',
        ),
      ),
    );
  } catch (e) {
    debugPrint('[TrafficLights] Failed to toggle traffic lights: $e');
  }
}
