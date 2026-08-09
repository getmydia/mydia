import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'fullscreen_backend.dart';
import 'fullscreen_backend_factory.dart';
import 'fullscreen_mode.dart';

/// Fullscreen state that reports what happened rather than what was asked.
///
/// Replaces `PlayerScreen`'s `bool _isFullscreen`, which was flipped inside
/// `setState` before the platform was asked and never corrected when the
/// platform refused or when the viewer exited by some other route. The same
/// defect was already fixed once for the desktop window; see
/// `WindowFullscreenController`'s class comment.
class FullscreenController {
  FullscreenController({
    FullscreenBackend Function(ValueChanged<bool>)? backendFactory,
    ValueNotifier<bool>? state,
  })  : _state = state ?? ValueNotifier<bool>(false),
        _ownsState = state == null {
    _backend = (backendFactory ?? _defaultBackend)(_set);
  }

  static FullscreenBackend _defaultBackend(ValueChanged<bool> onChange) =>
      createFullscreenBackend(onChange: onChange);

  final ValueNotifier<bool> _state;
  final bool _ownsState;
  late final FullscreenBackend _backend;

  /// Observed fullscreen state. Never written by this class directly.
  ValueListenable<bool> get isFullscreen => _state;

  FullscreenMode get mode => _backend.mode;

  /// False only where no fullscreen route exists, which is the signal to hide
  /// the button rather than render a dead one.
  bool get available => _backend.mode != FullscreenMode.unsupported;

  void attach(Player player) => _backend.attach(player);

  void _set(bool value) => _state.value = value;

  /// Synchronous by contract, and must stay that way: `webkitEnterFullscreen`
  /// needs live user activation, and an `await` between the tap and the call
  /// spends it. Changing this to `Future<void>` would break iPhone Safari in a
  /// way no test on a non-web host can catch.
  void toggle() => _state.value ? exit() : enter();

  void enter() => _backend.enter();

  void exit() => _backend.exit();

  void dispose() {
    _backend.dispose();
    if (_ownsState) _state.dispose();
  }
}
