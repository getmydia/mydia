import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';

/// Releases every live player before the app quits.
///
/// media_kit hands libmpv a Dart `NativeCallable` as its wakeup callback.
/// Quitting mid-playback shut the Flutter engine down, freeing that callback,
/// while mpv's core thread was still running, and its next property change
/// jumped into unmapped memory (EXC_BAD_ACCESS in
/// `mp_client_send_property_changes`). `Player.dispose()` clears the callback
/// first, but nothing disposed a playing player on quit.
///
/// Flutter asks Dart before the app exits (`AppLifecycleListener.
/// onExitRequested`, wired in `main.dart`), so each player screen registers
/// its release here and [onExitRequested] runs them all before answering.
class PlayerExitGuard {
  PlayerExitGuard({this.timeout = const Duration(seconds: 3)});

  static final PlayerExitGuard instance = PlayerExitGuard();

  /// The longest an exit waits. A release that hangs must not keep the app
  /// from quitting; quitting with a live player is no worse than before.
  final Duration timeout;

  final Set<_Registration> _registrations = {};

  /// Registers [release], which disposes one player. Unregister once that
  /// player is disposed by its own path.
  PlayerExitRegistration register(Future<void> Function() release) {
    final registration = _Registration(release, _registrations.remove);
    _registrations.add(registration);
    return registration;
  }

  /// Runs every registered release, then lets the app exit. Never cancels the
  /// exit and never throws.
  Future<AppExitResponse> onExitRequested() async {
    final releases = List.of(_registrations);
    _registrations.clear();
    if (releases.isEmpty) return AppExitResponse.exit;
    try {
      await Future.wait(releases.map((r) => _guarded(r.release)))
          .timeout(timeout);
    } on TimeoutException {
      debugPrint('[PlayerExitGuard] Player release timed out; exiting anyway');
    }
    return AppExitResponse.exit;
  }

  static Future<void> _guarded(Future<void> Function() release) async {
    try {
      await release();
    } catch (e) {
      debugPrint('[PlayerExitGuard] Player release failed: $e');
    }
  }
}

/// A player's place in [PlayerExitGuard].
abstract interface class PlayerExitRegistration {
  void unregister();
}

class _Registration implements PlayerExitRegistration {
  _Registration(this.release, this._remove);

  final Future<void> Function() release;
  final bool Function(Object?) _remove;

  @override
  void unregister() => _remove(this);
}
