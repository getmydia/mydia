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
  NativeFullscreenBackend({
    required this.onChange,
    @visibleForTesting ValueNotifier<bool>? windowSignal,
    @visibleForTesting bool? isWindows,
    @visibleForTesting VoidCallback? onEnterNative,
    @visibleForTesting VoidCallback? onExitNative,
  })  : _windowSignal = windowSignal,
        _isWindows = isWindows,
        _onEnterNative = onEnterNative ?? defaultEnterNativeFullscreen,
        _onExitNative = onExitNative ?? defaultExitNativeFullscreen;

  final ValueChanged<bool> onChange;
  final ValueNotifier<bool>? _windowSignal;
  final bool? _isWindows;
  final VoidCallback _onEnterNative;
  final VoidCallback _onExitNative;

  bool get _effectiveIsWindows => _isWindows ?? PlatformFeatures.isWindows;
  ValueNotifier<bool> get _effectiveWindowSignal =>
      _windowSignal ?? windowFullscreenSignal;

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
    _effectiveWindowSignal.addListener(_republish);
    _listening = true;
    _republish();
  }

  void _republish() => onChange(_effectiveWindowSignal.value);

  @override
  void enter() {
    _onEnterNative();
    // Mobile has no system event callback for `setEnabledSystemUIMode`, and
    // Windows has no OS-level fullscreen event callback (Win32 borderless
    // fullscreen is just a resized style-stripped window, and media_kit_video
    // does not emit window events). Both report optimistically, and on Windows
    // we also keep the app-wide `windowFullscreenSignal` in sync.
    if (_effectiveIsWindows) {
      _effectiveWindowSignal.value = true;
    }
    if (mode == FullscreenMode.systemUi ||
        (_effectiveIsWindows && !_listening)) {
      onChange(true);
    }
  }

  @override
  void exit() {
    _onExitNative();
    if (_effectiveIsWindows) {
      _effectiveWindowSignal.value = false;
    }
    if (mode == FullscreenMode.systemUi ||
        (_effectiveIsWindows && !_listening)) {
      onChange(false);
    }
  }

  @override
  void dispose() {
    if (_listening) {
      _effectiveWindowSignal.removeListener(_republish);
      _listening = false;
    }
    _ready.dispose();
  }
}
