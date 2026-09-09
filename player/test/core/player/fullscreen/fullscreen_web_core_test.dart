// The web backend's decisions, tested without a browser.
//
// `fullscreen_backend_web.dart` compiles only under `dart.library.js_interop`,
// and `flutter test` always runs non-web, so nothing in that file is reachable
// from here. Everything worth testing was moved behind `WebFullscreenPlatform`
// for exactly that reason -- the same trade `fullscreen_mode_test.dart` makes
// for `resolveWebMode`, applied to state rather than a single pure decision.
//
// The three defects these cover all presented identically on iOS Safari, as
// "the fullscreen button is there and does nothing":
//   1. the media element was bound once and never rebound
//   2. availability answered "this browser has an API", not "this will work"
//   3. a refused document request had nowhere to go, even though iPhone Safari
//      still has a working video element route

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/fullscreen/fullscreen_failure.dart';
import 'package:player/core/player/fullscreen/fullscreen_mode.dart';
import 'package:player/core/player/fullscreen/fullscreen_web_core.dart';
import 'package:player/core/player/fullscreen/fullscreen_web_platform.dart';

void main() {
  group('route selection', () {
    test('prefers the document route, which keeps Mydia chrome', () {
      final harness = _Harness();
      addTearDown(harness.dispose);

      expect(harness.core.mode, FullscreenMode.documentElement);
      expect(harness.core.ready.value, isTrue);
    });

    test('the document route is ready before anything is attached', () {
      final harness = _Harness();
      addTearDown(harness.dispose);

      expect(harness.core.report.mediaElementBound, isFalse);
      expect(harness.core.ready.value, isTrue);
    });

    test(
        'the video route is not ready until a player is attached, so the '
        'button is absent rather than inert', () {
      final harness = _Harness(documentFullscreenEnabled: false);
      addTearDown(harness.dispose);

      expect(harness.core.mode, FullscreenMode.nativeVideoElement);
      expect(harness.core.ready.value, isFalse);

      harness.core.attach(Object());

      expect(harness.core.ready.value, isTrue);
      expect(harness.core.report.mediaElementBound, isTrue);
    });

    test('no route at all is never ready', () {
      final harness = _Harness(
        documentFullscreenEnabled: false,
        videoElementFullscreenSupported: false,
      );
      addTearDown(harness.dispose);

      expect(harness.core.mode, FullscreenMode.unsupported);
      expect(harness.core.ready.value, isFalse);

      harness.core.attach(Object());

      expect(harness.core.ready.value, isFalse);
    });

    test('a probe that threw is recorded but not announced', () {
      const probe = FullscreenFailure(
        FullscreenFailureCause.documentEnabledProbeFailed,
        detail: 'boom',
      );
      final harness = _Harness(
        documentFullscreenEnabled: false,
        probeFailures: const [probe],
      );
      addTearDown(harness.dispose);

      expect(harness.core.report.lastFailure, probe);
      // Nobody asked for fullscreen yet. A message here would be noise.
      expect(harness.failures, isEmpty);
    });
  });

  group('rebinding across players', () {
    test('attaching the same player twice binds once', () {
      final harness = _Harness(documentFullscreenEnabled: false);
      addTearDown(harness.dispose);
      final player = Object();

      harness.core.attach(player);
      harness.core.attach(player);

      expect(harness.platform.boundPlayers, [player]);
    });

    test(
        'a second player rebinds, which is the episode change, quality switch '
        'and Retry case', () {
      final harness = _Harness(documentFullscreenEnabled: false);
      addTearDown(harness.dispose);
      final first = Object();
      final second = Object();

      harness.core.attach(first);
      harness.core.attach(second);

      expect(harness.platform.boundPlayers, [first, second]);
      expect(harness.core.ready.value, isTrue);
    });

    test('rebinding releases the previous element exactly once', () {
      final harness = _Harness(documentFullscreenEnabled: false);
      addTearDown(harness.dispose);

      harness.core.attach(Object());
      final afterFirst = harness.platform.unbindCalls;
      harness.core.attach(Object());

      // One from `attach` itself, one from `bindVideo`'s own release. What
      // matters is that the count moves, not that it moves by one: the point
      // is the old element's listeners are gone before the new ones land.
      expect(harness.platform.unbindCalls, greaterThan(afterFirst));
      expect(harness.platform.boundPlayers, hasLength(2));
    });

    test('dispose releases the element bound last, not the first', () {
      final harness = _Harness(documentFullscreenEnabled: false);
      final first = Object();
      final second = Object();

      harness.core.attach(first);
      harness.core.attach(second);
      harness.core.dispose();

      expect(harness.platform.lastUnboundPlayer, second);
    });

    test('a player with no media element leaves the route unready', () {
      final harness = _Harness(
        documentFullscreenEnabled: false,
        bindResult: FullscreenFailureCause.playerNotWebPlayer,
      );
      addTearDown(harness.dispose);

      harness.core.attach(Object());

      expect(harness.core.ready.value, isFalse);
      expect(harness.core.report.mediaElementBound, isFalse);
      expect(harness.failures, hasLength(1));
      expect(
        harness.failures.single.cause,
        FullscreenFailureCause.playerNotWebPlayer,
      );
      // The viewer never asked for fullscreen, so this one stays out of their
      // way; it is still in the readout.
      expect(harness.failures.single.requestInitiated, isFalse);
    });
  });

  group('the document route is refused', () {
    test('falls back to the video element and enters by that route', () {
      final harness = _Harness(documentRequestError: 'NotAllowedError');
      addTearDown(harness.dispose);
      harness.core.attach(Object());

      harness.core.enter();

      expect(harness.core.mode, FullscreenMode.nativeVideoElement);
      expect(harness.platform.enterVideoCalls, 1);
      expect(harness.core.ready.value, isTrue);
      expect(harness.core.report.demoted, isTrue);
    });

    test('a fallback that worked is not announced to the viewer', () {
      final harness = _Harness(documentRequestError: 'NotAllowedError');
      addTearDown(harness.dispose);
      harness.core.attach(Object());

      harness.core.enter();

      expect(harness.failures, isEmpty);
      // Still recorded, because the readout is how anyone learns the document
      // route is dead on this browser.
      expect(
        harness.core.report.lastFailure?.cause,
        FullscreenFailureCause.documentRequestRejected,
      );
    });

    test('later requests take the video route directly', () {
      final harness = _Harness(documentRequestError: 'NotAllowedError');
      addTearDown(harness.dispose);
      harness.core.attach(Object());

      harness.core.enter();
      harness.core.enter();

      expect(harness.platform.documentRequests, 1);
      expect(harness.platform.enterVideoCalls, 2);
    });

    test('the document listener is dropped on demotion', () {
      final harness = _Harness(documentRequestError: 'NotAllowedError');
      addTearDown(harness.dispose);
      harness.core.attach(Object());

      harness.core.enter();

      expect(harness.platform.stopListeningCalls, 1);
    });

    test('with no video route left, the control is withdrawn and announced',
        () {
      final harness = _Harness(
        videoElementFullscreenSupported: false,
        documentRequestError: 'NotAllowedError',
      );
      addTearDown(harness.dispose);
      harness.core.attach(Object());

      harness.core.enter();

      expect(harness.core.mode, FullscreenMode.unsupported);
      expect(harness.core.ready.value, isFalse);
      expect(harness.failures, hasLength(1));
      expect(
        harness.failures.single.cause,
        FullscreenFailureCause.documentRequestRejected,
      );
      expect(harness.failures.single.requestInitiated, isTrue);
    });

    test('a fallback that also fails is announced exactly once', () {
      final harness = _Harness(
        documentRequestError: 'NotAllowedError',
        videoEnterError: 'InvalidStateError',
      );
      addTearDown(harness.dispose);
      harness.core.attach(Object());

      harness.core.enter();

      expect(harness.failures, hasLength(1));
      expect(
        harness.failures.single.cause,
        FullscreenFailureCause.videoEnterFailed,
      );
      expect(harness.core.mode, FullscreenMode.unsupported);
      expect(harness.core.ready.value, isFalse);
    });

    test('a fallback with nothing to bind is announced exactly once', () {
      final harness = _Harness(
        documentRequestError: 'NotAllowedError',
        bindResult: FullscreenFailureCause.noVideoElement,
      );
      addTearDown(harness.dispose);
      harness.core.attach(Object());

      harness.core.enter();

      expect(harness.failures, hasLength(1));
      expect(harness.core.ready.value, isFalse);
    });
  });

  group('the video route is refused', () {
    test('entering with nothing bound withdraws the control', () {
      final harness = _Harness(documentFullscreenEnabled: false);
      addTearDown(harness.dispose);

      // Never attached, so nothing is bound.
      harness.core.enter();

      expect(harness.failures, hasLength(1));
      expect(
        harness.failures.single.cause,
        FullscreenFailureCause.noVideoElement,
      );
      expect(harness.core.mode, FullscreenMode.unsupported);
      expect(harness.core.ready.value, isFalse);
    });

    test('a throw from the browser withdraws the control', () {
      final harness = _Harness(
        documentFullscreenEnabled: false,
        videoEnterError: 'InvalidStateError',
      );
      addTearDown(harness.dispose);
      harness.core.attach(Object());

      harness.core.enter();

      expect(harness.failures, hasLength(1));
      expect(
        harness.failures.single.cause,
        FullscreenFailureCause.videoEnterFailed,
      );
      expect(harness.core.ready.value, isFalse);
    });
  });

  group('state comes from the platform', () {
    test('the document route reports through its listener, not the request',
        () {
      final harness = _Harness();
      addTearDown(harness.dispose);

      harness.core.enter();
      expect(harness.changes, isEmpty);

      harness.platform.emitDocumentFullscreen(true);
      expect(harness.changes, [true]);

      harness.platform.emitDocumentFullscreen(false);
      expect(harness.changes, [true, false]);
    });

    test('the video route reports through the element it bound', () {
      final harness = _Harness(documentFullscreenEnabled: false);
      addTearDown(harness.dispose);
      harness.core.attach(Object());

      harness.core.enter();
      expect(harness.changes, isEmpty);

      harness.platform.emitVideoFullscreen(true);
      expect(harness.changes, [true]);
    });

    test('exit is a no-op on a route with nothing bound', () {
      final harness = _Harness(documentFullscreenEnabled: false);
      addTearDown(harness.dispose);

      harness.core.exit();

      expect(harness.platform.exitVideoCalls, 0);
      expect(harness.failures, isEmpty);
    });

    test('a refused exit is announced but does not retire the route', () {
      final harness = _Harness(documentExitError: 'NotAllowedError');
      addTearDown(harness.dispose);

      harness.core.exit();

      expect(harness.failures, hasLength(1));
      expect(
        harness.failures.single.cause,
        FullscreenFailureCause.documentExitRejected,
      );
      expect(harness.core.mode, FullscreenMode.documentElement);
      expect(harness.core.ready.value, isTrue);
    });
  });
}

/// Wires a [WebFullscreenCore] to a fake browser and collects what came out.
class _Harness {
  _Harness({
    bool documentFullscreenEnabled = true,
    bool videoElementFullscreenSupported = true,
    List<FullscreenFailure> probeFailures = const [],
    FullscreenFailureCause? bindResult,
    Object? documentRequestError,
    Object? documentExitError,
    Object? videoEnterError,
  }) : platform = _FakePlatform(
          documentFullscreenEnabled: documentFullscreenEnabled,
          videoElementFullscreenSupported: videoElementFullscreenSupported,
          probeFailures: probeFailures,
          bindResult: bindResult,
          documentRequestError: documentRequestError,
          documentExitError: documentExitError,
          videoEnterError: videoEnterError,
        ) {
    core = WebFullscreenCore(
      platform: platform,
      onChange: changes.add,
      onFailure: failures.add,
    );
  }

  final _FakePlatform platform;
  late final WebFullscreenCore core;
  final List<bool> changes = [];
  final List<FullscreenFailure> failures = [];

  void dispose() => core.dispose();
}

class _FakePlatform implements WebFullscreenPlatform {
  _FakePlatform({
    required this.documentFullscreenEnabled,
    required this.videoElementFullscreenSupported,
    required this.probeFailures,
    required this.bindResult,
    required this.documentRequestError,
    required this.documentExitError,
    required this.videoEnterError,
  });

  @override
  final bool documentFullscreenEnabled;

  @override
  final bool videoElementFullscreenSupported;

  @override
  final List<FullscreenFailure> probeFailures;

  /// Non-null makes `bindVideo` fail with that cause.
  final FullscreenFailureCause? bindResult;

  final Object? documentRequestError;
  final Object? documentExitError;
  final Object? videoEnterError;

  final List<Object> boundPlayers = [];
  Object? lastUnboundPlayer;
  int unbindCalls = 0;
  int documentRequests = 0;
  int stopListeningCalls = 0;
  int enterVideoCalls = 0;
  int exitVideoCalls = 0;

  Object? _currentPlayer;
  void Function(bool)? _documentListener;
  void Function(bool)? _videoListener;

  void emitDocumentFullscreen(bool value) => _documentListener?.call(value);

  void emitVideoFullscreen(bool value) => _videoListener?.call(value);

  @override
  void listenDocumentFullscreen(void Function(bool fullscreen) onChange) =>
      _documentListener = onChange;

  @override
  void stopListeningDocumentFullscreen() {
    stopListeningCalls++;
    _documentListener = null;
  }

  @override
  void requestDocumentFullscreen(void Function(Object error) onRejected) {
    documentRequests++;
    final error = documentRequestError;
    // Synchronous, unlike a real promise rejection. The state machine treats
    // it the same either way, and a synchronous fake keeps the assertions
    // readable.
    if (error != null) onRejected(error);
  }

  @override
  void exitDocumentFullscreen(void Function(Object error) onRejected) {
    final error = documentExitError;
    if (error != null) onRejected(error);
  }

  @override
  FullscreenFailureCause? bindVideo(
    Object player, {
    required void Function(bool fullscreen) onChange,
  }) {
    unbindVideo();
    if (bindResult != null) return bindResult;
    boundPlayers.add(player);
    _currentPlayer = player;
    _videoListener = onChange;
    return null;
  }

  @override
  void unbindVideo() {
    unbindCalls++;
    if (_currentPlayer != null) lastUnboundPlayer = _currentPlayer;
    _currentPlayer = null;
    _videoListener = null;
  }

  @override
  void enterVideoFullscreen() {
    enterVideoCalls++;
    final error = videoEnterError;
    if (error != null) throw StateError('$error');
  }

  @override
  void exitVideoFullscreen() => exitVideoCalls++;
}
