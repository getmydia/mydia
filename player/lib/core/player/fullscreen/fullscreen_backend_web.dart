import 'dart:js_interop';
// `JSObject.operator []` and `JSObject.has` live here, not in
// `dart:js_interop`, as of Dart 3.12.2. Omitting this import fails the web
// build with "The operator '[]' isn't defined for the type 'JSObject'" and
// "The method 'has' isn't defined for the type 'JSObject'".
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
  web.HTMLVideoElement? _video;
  JSFunction? _beginListener;
  JSFunction? _endListener;

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

  /// Flips media_kit's subtitle `<track>` between browser-rendered and
  /// Flutter-rendered.
  ///
  /// media_kit appends a real `<track>` element and immediately sets
  /// `mode = 'hidden'` (`media_kit/lib/src/player/web/player/real.dart:1358`
  /// and `:1379`), then pipes cue text into Dart for the Flutter layer to
  /// paint. Apple's fullscreen shows only the video element, so without this
  /// the subtitles vanish.
  ///
  /// Index 0 on purpose: it is the track media_kit's own cue listener binds to
  /// (`real.dart:1376`), so fullscreen renders exactly what the inline player
  /// renders. Note that media_kit appends a fresh `<track>` per
  /// `setSubtitleTrack` and only ever removes stale `<source>` elements
  /// (`real.dart:1282`), never stale `<track>` elements, so after a second
  /// subtitle switch index 0 is the first subtitle chosen that session and the
  /// inline player is *already* showing the wrong cues. Matching that is
  /// deliberate: a fullscreen path that was correct while inline stayed wrong
  /// would be harder to diagnose than consistent wrongness. Tracked as a
  /// separate upstream issue.
  void _setTextTrackMode(String mode) {
    try {
      final tracks = _video?.textTracks;
      if (tracks == null || tracks.length == 0) return;
      tracks[0].mode = mode;
    } catch (e) {
      debugPrint('[Fullscreen] text track mode $mode failed: $e');
    }
  }

  @override
  void attach(Player player) {
    if (_mode != FullscreenMode.nativeVideoElement || _video != null) return;

    // media_kit exports its web player publicly:
    // `package:media_kit/media_kit.dart` re-exports
    // `src/player/web/player/player.dart`, itself
    // `export 'stub.dart' if (dart.library.js_interop) 'real.dart';`. On a web
    // build that resolves to `WebPlayer`, whose `element` field is public. This
    // file only compiles on web, so the cast is safe and needs no `src/`
    // import, no `$com.alexmercerind.media_kit.instances` global, and no
    // `querySelector` guessing.
    final platform = player.platform;
    if (platform is! WebPlayer) {
      debugPrint('[Fullscreen] player.platform is not a WebPlayer');
      return;
    }
    // `WebPlayer.element` exists on media_kit's web `real.dart`, which
    // `flutter build web` resolves. `dart analyze` / `flutter analyze` resolve
    // the same conditional export to `stub.dart`, which has no `element`, so
    // a static read fails analysis even though the web compiler accepts it.
    // Same runtime API the plan specifies; dynamic only bridges the stub gap.
    final video = (platform as dynamic).element as web.HTMLVideoElement;
    _video = video;

    _beginListener = ((web.Event _) {
      // Apple renders only the video element, so hand the browser the cues
      // media_kit normally keeps hidden and paints through Flutter.
      _setTextTrackMode('showing');
      onChange(true);
    }).toJS;
    _endListener = ((web.Event _) {
      _setTextTrackMode('hidden');
      onChange(false);
    }).toJS;

    video.addEventListener('webkitbeginfullscreen', _beginListener!);
    video.addEventListener('webkitendfullscreen', _endListener!);
  }

  @override
  void enter() {
    switch (_mode) {
      case FullscreenMode.documentElement:
        final element = web.document.documentElement;
        if (element == null) return;
        element.requestFullscreen().toDart.catchError((Object e) {
          debugPrint('[Fullscreen] requestFullscreen rejected: $e');
          return null;
        });
      case FullscreenMode.nativeVideoElement:
        final video = _video;
        if (video == null) {
          debugPrint('[Fullscreen] no video element attached');
          return;
        }
        try {
          // Called synchronously on the tap frame. `webkitEnterFullscreen`
          // requires live user activation and any await above would spend it.
          (video as JSObject).callMethod('webkitEnterFullscreen'.toJS);
        } catch (e) {
          debugPrint('[Fullscreen] webkitEnterFullscreen failed: $e');
        }
      case FullscreenMode.osWindow:
      case FullscreenMode.systemUi:
      case FullscreenMode.unsupported:
        return;
    }
  }

  @override
  void exit() {
    switch (_mode) {
      case FullscreenMode.documentElement:
        if (web.document.fullscreenElement == null) return;
        web.document.exitFullscreen().toDart.catchError((Object e) {
          debugPrint('[Fullscreen] exitFullscreen rejected: $e');
          return null;
        });
      case FullscreenMode.nativeVideoElement:
        final video = _video;
        if (video == null) return;
        try {
          (video as JSObject).callMethod('webkitExitFullscreen'.toJS);
        } catch (e) {
          debugPrint('[Fullscreen] webkitExitFullscreen failed: $e');
        }
      case FullscreenMode.osWindow:
      case FullscreenMode.systemUi:
      case FullscreenMode.unsupported:
        return;
    }
  }

  @override
  void dispose() {
    final documentListener = _documentListener;
    if (documentListener != null) {
      web.document.removeEventListener('fullscreenchange', documentListener);
      _documentListener = null;
    }

    // The player screen mounts repeatedly across SPA navigations, so leaked
    // listeners on a long-lived video element would accumulate.
    final video = _video;
    if (video != null) {
      final begin = _beginListener;
      final end = _endListener;
      if (begin != null) {
        video.removeEventListener('webkitbeginfullscreen', begin);
      }
      if (end != null) {
        video.removeEventListener('webkitendfullscreen', end);
      }
    }
    _beginListener = null;
    _endListener = null;
    _video = null;
  }
}
