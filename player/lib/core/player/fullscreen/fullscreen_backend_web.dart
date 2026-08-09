import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:web/web.dart' as web;

import 'fullscreen_backend.dart';
import 'fullscreen_mode.dart';

FullscreenBackend createFullscreenBackend({
  required ValueChanged<bool> onChange,
}) =>
    WebFullscreenBackend(onChange: onChange);

/// Browser fullscreen, over whichever route the browser actually offers.
///
/// Both routes are event-sourced. That is the point: media_kit's own
/// `defaultEnterNativeFullscreen` catches every failure to `debugPrint` and
/// returns, leaving the caller believing it worked, which is exactly how the
/// icon came to lie on iPhone Safari.
class WebFullscreenBackend implements FullscreenBackend {
  WebFullscreenBackend({required this.onChange}) {
    _mode = resolveWebMode(
      documentFullscreenEnabled: _documentFullscreenEnabled,
      videoElementFullscreenSupported: _videoElementFullscreenSupported,
    );
    if (_mode == FullscreenMode.documentElement) {
      _documentListener = _onDocumentFullscreenChange.toJS;
      web.document.addEventListener('fullscreenchange', _documentListener);
    }
  }

  final ValueChanged<bool> onChange;

  late final FullscreenMode _mode;
  JSFunction? _documentListener;

  @override
  FullscreenMode get mode => _mode;

  /// `document.fullscreenEnabled`, not a probe for `requestFullscreen`. It is
  /// also false inside an iframe lacking `allow="fullscreen"`, so one read
  /// covers both cases that must fall back.
  static bool get _documentFullscreenEnabled {
    try {
      return web.document.fullscreenEnabled;
    } catch (e) {
      debugPrint('[Fullscreen] fullscreenEnabled read failed: $e');
      return false;
    }
  }

  /// Probed on the prototype, never on a live element:
  /// `video.webkitSupportsFullscreen` stays false until metadata loads, and
  /// the button has to decide whether to exist before then.
  static bool get _videoElementFullscreenSupported {
    try {
      final ctor = globalContext['HTMLVideoElement'];
      if (ctor.isUndefinedOrNull) return false;
      final proto = (ctor as JSObject)['prototype'];
      if (proto.isUndefinedOrNull) return false;
      return (proto as JSObject).has('webkitEnterFullscreen');
    } catch (e) {
      debugPrint('[Fullscreen] video prototype probe failed: $e');
      return false;
    }
  }

  void _onDocumentFullscreenChange(web.Event _) {
    onChange(web.document.fullscreenElement != null);
  }

  @override
  void attach(Player player) {
    // Task 6 reaches the HTMLVideoElement here for the nativeVideoElement
    // route. Nothing to do for documentElement.
  }

  @override
  void enter() {
    if (_mode != FullscreenMode.documentElement) return;
    final element = web.document.documentElement;
    if (element == null) return;
    // Not awaited on purpose: an `await` here would be harmless for this route
    // but the sibling route cannot afford one, and a single synchronous shape
    // keeps the user-activation contract obvious. The rejection is still
    // handled so it never surfaces as an unhandled promise.
    element.requestFullscreen().toDart.catchError((Object e) {
      debugPrint('[Fullscreen] requestFullscreen rejected: $e');
      return null;
    });
  }

  @override
  void exit() {
    if (_mode != FullscreenMode.documentElement) return;
    if (web.document.fullscreenElement == null) return;
    web.document.exitFullscreen().toDart.catchError((Object e) {
      debugPrint('[Fullscreen] exitFullscreen rejected: $e');
      return null;
    });
  }

  @override
  void dispose() {
    final listener = _documentListener;
    if (listener != null) {
      web.document.removeEventListener('fullscreenchange', listener);
      _documentListener = null;
    }
  }
}
