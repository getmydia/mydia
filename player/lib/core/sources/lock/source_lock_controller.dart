/// Whether locked and hidden sources are open right now. Memory only: a
/// cold start is always locked.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_auth.dart';
import 'pin_store.dart';

/// How long the app may sit in the background before it locks again.
const kRelockGrace = Duration(minutes: 1);

/// The unlock screen, returning to [next] on success.
String unlockLocation(String next) =>
    '/unlock?next=${Uri.encodeQueryComponent(next)}';

class SourceLockController extends Notifier<bool> {
  Timer? _relock;
  int _holds = 0;
  bool _lockWhenReleased = false;

  @override
  bool build() {
    ref.onDispose(() => _relock?.cancel());
    return false;
  }

  /// True while a locked or hidden source is playing.
  bool get holding => _holds > 0;

  Future<DeviceAuthResult> unlockWithDevice() async {
    final result = await ref.read(deviceAuthProvider).authenticate();
    if (result == DeviceAuthResult.success) _unlock();
    return result;
  }

  Future<PinCheck> unlockWithPin(String pin) async {
    final result = await ref.read(pinStoreProvider).check(pin);
    if (result is PinAccepted) _unlock();
    return result;
  }

  void lock() {
    _relock?.cancel();
    _relock = null;
    _lockWhenReleased = false;
    state = false;
  }

  /// Keeps the app unlocked while a locked or hidden source plays, so a
  /// stream in the background is not cut off. Returns the release.
  void Function() hold() {
    _holds++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _holds--;
      if (_holds == 0 && _lockWhenReleased) lock();
    };
  }

  void onLifecycle(AppLifecycleState lifecycle) {
    switch (lifecycle) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        if (state && _relock == null) _relock = Timer(kRelockGrace, _expire);
      case AppLifecycleState.resumed:
        _relock?.cancel();
        _relock = null;
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  void _expire() {
    _relock = null;
    if (holding) {
      _lockWhenReleased = true;
    } else {
      lock();
    }
  }

  void _unlock() {
    _lockWhenReleased = false;
    state = true;
  }
}

final sourceLockProvider =
    NotifierProvider<SourceLockController, bool>(SourceLockController.new);
