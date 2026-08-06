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

/// Whether [setTrafficLightsHidden] should touch the native buttons at all.
///
/// False off macOS (no traffic lights to control) and while fullscreen,
/// where macOS already hides them on its own — forcing them visible there
/// would fight the OS's own transition.
@visibleForTesting
bool shouldControlTrafficLights({
  required TargetPlatform platform,
  required bool isFullscreen,
}) =>
    platform == TargetPlatform.macOS && !isFullscreen;

/// Hides or shows the native close/minimize/zoom buttons.
///
/// Fire-and-forget: callers do not await this, so any failure is caught and
/// logged here rather than propagating.
void setTrafficLightsHidden(bool hidden) {
  if (!shouldControlTrafficLights(
    platform: defaultTargetPlatform,
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
