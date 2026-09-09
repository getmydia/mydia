import 'package:flutter/foundation.dart';

import 'fullscreen_backend.dart';
import 'fullscreen_failure.dart';
import 'fullscreen_mode.dart';
import 'fullscreen_report.dart';
import 'fullscreen_web_platform.dart';

/// Everything the web backend decides, with no browser in sight.
///
/// `WebFullscreenBackend` is now an adapter over this: it implements
/// [WebFullscreenPlatform] with `package:web` and forwards. The split exists so
/// the branching can be tested at all. See `fullscreen_web_platform.dart`.
///
/// Three behaviours live here that the previous implementation got wrong, all
/// of which presented identically as "the fullscreen button does nothing":
///
/// 1. **Rebinding.** [attach] is keyed on the player's identity, not on whether
///    an element was ever bound. `PlayerScreen` builds a fresh `Player` on every
///    source load, and the old `if (_video != null) return` meant that from the
///    second episode, quality switch or Retry onward the backend was
///    fullscreening a disposed element.
/// 2. **Readiness.** [ready] answers "would a request now be carried out",
///    where the old `available` answered "does this browser have an API". The
///    control follows readiness, so it is absent rather than inert.
/// 3. **Demotion.** A refused document request falls back to the media element
///    route for the rest of the session. On a current iPhone
///    `document.fullscreenEnabled` is true, so the document route always wins at
///    construction and the video route written for that device was unreachable.
class WebFullscreenCore {
  WebFullscreenCore({
    required this.platform,
    required this.onChange,
    required this.onFailure,
  }) {
    _documentEnabled = platform.documentFullscreenEnabled;
    _videoSupported = platform.videoElementFullscreenSupported;
    _mode = resolveWebMode(
      documentFullscreenEnabled: _documentEnabled,
      videoElementFullscreenSupported: _videoSupported,
    );
    if (_mode == FullscreenMode.documentElement) {
      platform.listenDocumentFullscreen(onChange);
    }
    // Probe failures are real and belong in the readout, but nobody asked for
    // fullscreen yet, so they are recorded rather than announced. Nothing is
    // subscribed this early in any case; the report is where they are read.
    for (final failure in platform.probeFailures) {
      _record(failure, emit: false);
    }
    _ready = ValueNotifier<bool>(_computeReady());
  }

  final WebFullscreenPlatform platform;
  final ValueChanged<bool> onChange;
  final FullscreenFailureSink onFailure;

  late final bool _documentEnabled;
  late final bool _videoSupported;

  /// Mutable, unlike its native counterpart: [_demoteAfterRefusal] moves it
  /// once when a route is refused at request time.
  late FullscreenMode _mode;

  late final ValueNotifier<bool> _ready;

  Object? _player;
  bool _videoBound = false;
  bool _demoted = false;
  FullscreenFailure? _lastFailure;

  FullscreenMode get mode => _mode;

  ValueListenable<bool> get ready => _ready;

  FullscreenReport get report => FullscreenReport(
        mode: _mode,
        ready: _ready.value,
        mediaElementBound: _videoBound,
        demoted: _demoted,
        lastFailure: _lastFailure,
        documentFullscreenEnabled: _documentEnabled,
        videoElementFullscreenSupported: _videoSupported,
      );

  /// Binds the media element of [player], releasing any previous one.
  ///
  /// A repeat call with the same instance is a no-op, so the four
  /// `_initializePlayer` call sites need no bookkeeping of their own. The
  /// player is retained even on the document route, because [_demoteAfterRefusal]
  /// may need it later.
  void attach(Object player) {
    if (identical(_player, player)) return;
    platform.unbindVideo();
    _videoBound = false;
    _player = player;
    _bindVideoIfNeeded(requestInitiated: false);
    _updateReady();
  }

  void enter() {
    switch (_mode) {
      case FullscreenMode.documentElement:
        platform.requestDocumentFullscreen(_onDocumentRequestRejected);
      case FullscreenMode.nativeVideoElement:
        _enterVideo();
      case FullscreenMode.osWindow:
      case FullscreenMode.systemUi:
      case FullscreenMode.unsupported:
        return;
    }
  }

  void exit() {
    switch (_mode) {
      case FullscreenMode.documentElement:
        platform.exitDocumentFullscreen((error) => _record(
              FullscreenFailure(
                FullscreenFailureCause.documentExitRejected,
                detail: '$error',
                requestInitiated: true,
              ),
            ));
      case FullscreenMode.nativeVideoElement:
        if (!_videoBound) return;
        try {
          platform.exitVideoFullscreen();
        } catch (e) {
          _record(FullscreenFailure(
            FullscreenFailureCause.videoExitFailed,
            detail: '$e',
            requestInitiated: true,
          ));
        }
      case FullscreenMode.osWindow:
      case FullscreenMode.systemUi:
      case FullscreenMode.unsupported:
        return;
    }
  }

  void dispose() {
    platform.stopListeningDocumentFullscreen();
    platform.unbindVideo();
    _ready.dispose();
  }

  // --- internals -----------------------------------------------------------

  bool _computeReady() => switch (_mode) {
        FullscreenMode.documentElement => true,
        FullscreenMode.nativeVideoElement => _videoBound,
        FullscreenMode.osWindow => true,
        FullscreenMode.systemUi => true,
        FullscreenMode.unsupported => false,
      };

  void _updateReady() => _ready.value = _computeReady();

  /// [emit] is false on the demotion path, where the caller announces whatever
  /// ends up being the final word. Announcing here as well would report the
  /// same refused tap twice.
  void _bindVideoIfNeeded({required bool requestInitiated, bool emit = true}) {
    if (_mode != FullscreenMode.nativeVideoElement) return;
    final player = _player;
    if (player == null) return;

    final cause = platform.bindVideo(player, onChange: onChange);
    if (cause != null) {
      _videoBound = false;
      _record(
        FullscreenFailure(cause, requestInitiated: requestInitiated),
        emit: emit,
      );
      return;
    }
    _videoBound = true;
  }

  void _enterVideo() {
    if (!_videoBound) {
      _record(const FullscreenFailure(
        FullscreenFailureCause.noVideoElement,
        requestInitiated: true,
      ));
      _demoteAfterRefusal();
      _updateReady();
      return;
    }
    try {
      platform.enterVideoFullscreen();
    } catch (e) {
      _record(FullscreenFailure(
        FullscreenFailureCause.videoEnterFailed,
        detail: '$e',
        requestInitiated: true,
      ));
      _demoteAfterRefusal();
      _updateReady();
    }
  }

  /// The document route was refused. Fall back if there is anywhere to fall
  /// back to, and retry the request on the new route immediately.
  ///
  /// The retry is worth attempting rather than deferring to the next tap: the
  /// rejection arrives off a promise, so transient user activation is usually
  /// still live. Not throwing is the strongest synchronous signal available;
  /// the authoritative answer is the `webkitbeginfullscreen` event, which
  /// [onChange] carries whenever it arrives.
  ///
  /// The refusal itself is only announced when there is nothing left to try.
  /// If the fallback works the viewer got what they asked for, and the readout
  /// still records what happened on the way.
  void _onDocumentRequestRejected(Object error) {
    _record(
      FullscreenFailure(
        FullscreenFailureCause.documentRequestRejected,
        detail: '$error',
        requestInitiated: true,
      ),
      emit: false,
    );

    final fellBack = _demoteAfterRefusal();
    _updateReady();

    if (!fellBack) {
      onFailure(_lastFailure!);
      return;
    }
    _enterVideo();
  }

  /// Moves to the route left after a refusal. Returns whether a usable one
  /// remains. One-way: see [demoteWebMode].
  bool _demoteAfterRefusal() {
    final next = demoteWebMode(
      current: _mode,
      videoElementFullscreenSupported: _videoSupported,
    );
    if (next == _mode) return false;

    if (_mode == FullscreenMode.documentElement) {
      platform.stopListeningDocumentFullscreen();
    }
    _mode = next;
    _demoted = true;

    if (_mode == FullscreenMode.nativeVideoElement) {
      _bindVideoIfNeeded(requestInitiated: true, emit: false);
      return _videoBound;
    }

    platform.unbindVideo();
    _videoBound = false;
    return false;
  }

  void _record(FullscreenFailure failure, {bool emit = true}) {
    _lastFailure = failure;
    if (emit) onFailure(failure);
  }
}
