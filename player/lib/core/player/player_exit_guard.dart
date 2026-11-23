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

  /// Releases and disposes under way. An exit waits for every one.
  final Set<Future<void>> _pending = {};

  /// True while [onExitRequested] waits. A player registered then is
  /// released at once, so a load that finishes mid-exit leaves nothing live.
  bool _exiting = false;

  /// Registers [release], which disposes one player. Unregister once that
  /// player's own dispose has started, and hand that dispose to [track].
  PlayerExitRegistration register(Future<void> Function() release) {
    final registration = _Registration(release, _registrations.remove);
    if (_exiting) {
      unawaited(track(_guarded(release)));
    } else {
      _registrations.add(registration);
    }
    return registration;
  }

  /// Keeps an exit waiting until [dispose] completes. For a dispose that
  /// started on its own path (leaving the player, switching files), which
  /// can still be running when the viewer quits.
  Future<void> track(Future<void> dispose) {
    final guarded = _guarded(() => dispose);
    _pending.add(guarded);
    guarded.whenComplete(() => _pending.remove(guarded));
    return dispose;
  }

  /// Runs every registered release and waits for every tracked dispose,
  /// then lets the app exit. Never cancels the exit and never throws.
  Future<AppExitResponse> onExitRequested() async {
    _exiting = true;
    try {
      for (final r in List.of(_registrations)) {
        unawaited(track(_guarded(r.release)));
      }
      _registrations.clear();
      await _drain().timeout(timeout);
    } on TimeoutException {
      debugPrint('[PlayerExitGuard] Player release timed out; exiting anyway');
    } finally {
      _exiting = false;
    }
    return AppExitResponse.exit;
  }

  /// Waits until nothing is pending, including work added while waiting.
  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      await Future.wait(List.of(_pending));
    }
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
