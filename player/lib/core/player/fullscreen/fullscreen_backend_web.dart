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
import 'fullscreen_failure.dart';
import 'fullscreen_mode.dart';
import 'fullscreen_report.dart';
import 'fullscreen_web_core.dart';
import 'fullscreen_web_platform.dart';

FullscreenBackend createFullscreenBackend({
  required ValueChanged<bool> onChange,
  required FullscreenFailureSink onFailure,
}) =>
    WebFullscreenBackend(onChange: onChange, onFailure: onFailure);

/// Browser fullscreen, over whichever route the browser actually offers.
///
/// Both routes are event-sourced. That is the point: media_kit's own
/// `defaultEnterNativeFullscreen` catches every failure to `debugPrint` and
/// returns, leaving the caller believing it worked, which is exactly how the
/// icon came to lie on iPhone Safari.
///
/// Every decision lives in [WebFullscreenCore]; this class is the
/// [WebFullscreenPlatform] half, and holds nothing but the `package:web` calls
/// and the element handles they need. The split is what makes any of it
/// testable: this file compiles only under `dart.library.js_interop`, so
/// `flutter test`, which always runs non-web, can never reach it.
class WebFullscreenBackend implements FullscreenBackend, WebFullscreenPlatform {
  WebFullscreenBackend({
    required ValueChanged<bool> onChange,
    required FullscreenFailureSink onFailure,
  }) {
    _core = WebFullscreenCore(
      platform: this,
      onChange: onChange,
      onFailure: onFailure,
    );
  }

  late final WebFullscreenCore _core;

  JSFunction? _documentListener;
  web.HTMLVideoElement? _video;
  JSFunction? _beginListener;
  JSFunction? _endListener;
  final List<FullscreenFailure> _probeFailures = <FullscreenFailure>[];

  // --- FullscreenBackend ---------------------------------------------------

  @override
  FullscreenMode get mode => _core.mode;

  @override
  ValueListenable<bool> get ready => _core.ready;

  @override
  FullscreenReport get report => _core.report;

  @override
  void attach(Player player) => _core.attach(player);

  @override
  void enter() => _core.enter();

  @override
  void exit() => _core.exit();

  @override
  void dispose() => _core.dispose();

  // --- WebFullscreenPlatform: capability probes ----------------------------

  /// `document.fullscreenEnabled`, not a probe for `requestFullscreen`. It is
  /// also false inside an iframe lacking `allow="fullscreen"`, so one read
  /// covers both cases that must fall back.
  @override
  bool get documentFullscreenEnabled {
    try {
      return web.document.fullscreenEnabled;
    } catch (e) {
      _probeFailures.add(FullscreenFailure(
        FullscreenFailureCause.documentEnabledProbeFailed,
        detail: '$e',
      ));
      return false;
    }
  }

  /// Probed on the prototype, never on a live element:
  /// `video.webkitSupportsFullscreen` stays false until metadata loads, and
  /// the button has to decide whether to exist before then.
  @override
  bool get videoElementFullscreenSupported {
    try {
      final ctor = globalContext['HTMLVideoElement'];
      if (ctor.isUndefinedOrNull) return false;
      final proto = (ctor as JSObject)['prototype'];
      if (proto.isUndefinedOrNull) return false;
      return (proto as JSObject).has('webkitEnterFullscreen');
    } catch (e) {
      _probeFailures.add(FullscreenFailure(
        FullscreenFailureCause.videoSupportProbeFailed,
        detail: '$e',
      ));
      return false;
    }
  }

  @override
  List<FullscreenFailure> get probeFailures => _probeFailures;

  // --- WebFullscreenPlatform: the document route ---------------------------

  @override
  void listenDocumentFullscreen(void Function(bool fullscreen) onChange) {
    if (_documentListener != null) return;
    _documentListener = ((web.Event _) {
      onChange(web.document.fullscreenElement != null);
    }).toJS;
    web.document.addEventListener('fullscreenchange', _documentListener!);
  }

  @override
  void stopListeningDocumentFullscreen() {
    final listener = _documentListener;
    if (listener == null) return;
    web.document.removeEventListener('fullscreenchange', listener);
    _documentListener = null;
  }

  @override
  void requestDocumentFullscreen(void Function(Object error) onRejected) {
    final element = web.document.documentElement;
    if (element == null) {
      onRejected('document.documentElement is null');
      return;
    }
    element.requestFullscreen().toDart.catchError((Object e) {
      debugPrint('[Fullscreen] requestFullscreen rejected: $e');
      onRejected(e);
      return null;
    });
  }

  @override
  void exitDocumentFullscreen(void Function(Object error) onRejected) {
    if (web.document.fullscreenElement == null) return;
    web.document.exitFullscreen().toDart.catchError((Object e) {
      debugPrint('[Fullscreen] exitFullscreen rejected: $e');
      onRejected(e);
      return null;
    });
  }

  // --- WebFullscreenPlatform: the media element route ----------------------

  @override
  FullscreenFailureCause? bindVideo(
    Object player, {
    required void Function(bool fullscreen) onChange,
  }) {
    unbindVideo();

    if (player is! Player) return FullscreenFailureCause.playerNotWebPlayer;

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
      return FullscreenFailureCause.playerNotWebPlayer;
    }
    // `WebPlayer.element` exists on media_kit's web `real.dart`, which
    // `flutter build web` resolves. `dart analyze` / `flutter analyze` resolve
    // the same conditional export to `stub.dart`, which has no `element`, so
    // a static read fails analysis even though the web compiler accepts it.
    // Same runtime API the plan specifies; dynamic only bridges the stub gap.
    final video = (platform as dynamic).element as web.HTMLVideoElement?;
    if (video == null) return FullscreenFailureCause.noVideoElement;
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
    return null;
  }

  /// Releases the bound element.
  ///
  /// The player screen mounts repeatedly across SPA navigations and builds a
  /// fresh `Player` on every source load, so leaked listeners would accumulate
  /// on elements nobody is playing any more.
  @override
  void unbindVideo() {
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

  @override
  void enterVideoFullscreen() {
    final video = _video;
    if (video == null) throw StateError('no video element attached');
    // Called synchronously on the tap frame. `webkitEnterFullscreen` requires
    // live user activation and any await above would spend it.
    (video as JSObject).callMethod('webkitEnterFullscreen'.toJS);
  }

  @override
  void exitVideoFullscreen() {
    final video = _video;
    if (video == null) return;
    (video as JSObject).callMethod('webkitExitFullscreen'.toJS);
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
}
