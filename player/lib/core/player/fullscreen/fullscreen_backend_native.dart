import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../window/window_fullscreen.dart';
import '../platform_features.dart';
import 'fullscreen_backend.dart';
import 'fullscreen_mode.dart';
import 'fullscreen_report.dart';

FullscreenBackend createFullscreenBackend({
  required ValueChanged<bool> onChange,
  required FullscreenFailureSink onFailure,
}) =>
    NativeFullscreenBackend(onChange: onChange);

/// Native fullscreen, behaviour-identical to what `PlayerScreen` did before
/// this controller existed: it calls the same two media_kit helpers, which
/// branch internally between `SystemUiMode.immersiveSticky` on mobile and a
/// method channel on desktop (`video_texture.dart:479`).
///
/// What is new is where state comes from. On desktop it republishes the
/// existing `windowFullscreen` signal rather than assuming, so the green
/// button, the View menu and Cmd+Ctrl+F are all reflected — the exact reason
/// `WindowFullscreenController` was written. That controller stays the only
/// writer of the signal; this only listens.
///
/// It takes no `onFailure`: neither `defaultEnterNativeFullscreen` nor
/// `defaultExitNativeFullscreen` reports one, so inventing failures here would
/// be the same guessing the web backend was fixed to stop doing.
class NativeFullscreenBackend implements FullscreenBackend {
  NativeFullscreenBackend({required this.onChange});

  final ValueChanged<bool> onChange;

  /// Both native routes exist unconditionally, so this never moves. It is a
  /// notifier rather than a constant only because the interface is shaped for
  /// web, where readiness genuinely changes.
  final ValueNotifier<bool> _ready = ValueNotifier<bool>(true);

  @override
  ValueListenable<bool> get ready => _ready;

  @override
  FullscreenMode get mode => PlatformFeatures.isDesktop
      ? FullscreenMode.osWindow
      : FullscreenMode.systemUi;

  @override
  FullscreenReport get report =>
      FullscreenReport(mode: mode, ready: _ready.value);

  bool _listening = false;

  @override
  void attach(Player player) {
    if (mode != FullscreenMode.osWindow || _listening) return;
    windowFullscreen.addListener(_republish);
    _listening = true;
    _republish();
  }

  void _republish() => onChange(windowFullscreen.value);

  @override
  void enter() {
    defaultEnterNativeFullscreen();
    // The one mode with no event source: `setEnabledSystemUIMode` has no
    // callback, so mobile reports optimistically. No worse than before, and
    // isolated to the platform that cannot do better.
    if (mode == FullscreenMode.systemUi) onChange(true);
  }

  @override
  void exit() {
    defaultExitNativeFullscreen();
    if (mode == FullscreenMode.systemUi) onChange(false);
  }

  @override
  void dispose() {
    if (_listening) {
      windowFullscreen.removeListener(_republish);
      _listening = false;
    }
    _ready.dispose();
  }
}
