import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'fullscreen_backend.dart';
import 'fullscreen_backend_factory.dart';
import 'fullscreen_failure.dart';
import 'fullscreen_mode.dart';
import 'fullscreen_report.dart';

/// Builds the platform backend. Takes both sinks so a test can drive state and
/// failures independently of any platform.
typedef FullscreenBackendFactory = FullscreenBackend Function(
  ValueChanged<bool> onChange,
  FullscreenFailureSink onFailure,
);

/// Fullscreen state that reports what happened rather than what was asked.
///
/// Replaces `PlayerScreen`'s `bool _isFullscreen`, which was flipped inside
/// `setState` before the platform was asked and never corrected when the
/// platform refused or when the viewer exited by some other route. The same
/// defect was already fixed once for the desktop window; see
/// `WindowFullscreenController`'s class comment.
class FullscreenController {
  FullscreenController({
    FullscreenBackendFactory? backendFactory,
    ValueNotifier<bool>? state,
  })  : _state = state ?? ValueNotifier<bool>(false),
        _ownsState = state == null {
    _backend = (backendFactory ?? _defaultBackend)(_set, _fail);
  }

  static FullscreenBackend _defaultBackend(
    ValueChanged<bool> onChange,
    FullscreenFailureSink onFailure,
  ) =>
      createFullscreenBackend(onChange: onChange, onFailure: onFailure);

  final ValueNotifier<bool> _state;
  final bool _ownsState;
  late final FullscreenBackend _backend;
  final StreamController<FullscreenFailure> _failures =
      StreamController<FullscreenFailure>.broadcast();

  /// Observed fullscreen state. Never written by this class directly.
  ValueListenable<bool> get isFullscreen => _state;

  FullscreenMode get mode => _backend.mode;

  /// Whether a request made right now would be carried out, which is what the
  /// control's presence must follow.
  ///
  /// This used to be `mode != unsupported`, a capability probe resolved once at
  /// construction. It stayed true when the web backend had bailed out of
  /// binding a media element and when every `requestFullscreen()` was being
  /// rejected, so the button was drawn over a route that could not work. The
  /// backend owns this the same way it owns [isFullscreen].
  ValueListenable<bool> get available => _backend.ready;

  /// Refusals, for whoever wants to tell the viewer. Broadcast, so a screen can
  /// subscribe and unsubscribe without consuming them for anyone else.
  Stream<FullscreenFailure> get failures => _failures.stream;

  /// A snapshot for the diagnostics readout.
  FullscreenReport get report => _backend.report;

  void attach(Player player) => _backend.attach(player);

  void _set(bool value) => _state.value = value;

  void _fail(FullscreenFailure failure) {
    if (!_failures.isClosed) _failures.add(failure);
  }

  /// Synchronous by contract, and must stay that way: `webkitEnterFullscreen`
  /// needs live user activation, and an `await` between the tap and the call
  /// spends it. Changing this to `Future<void>` would break iPhone Safari in a
  /// way no test on a non-web host can catch.
  void toggle() => _state.value ? exit() : enter();

  void enter() => _backend.enter();

  void exit() => _backend.exit();

  void dispose() {
    _backend.dispose();
    _failures.close();
    if (_ownsState) _state.dispose();
  }
}
