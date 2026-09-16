import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks whether a local `PlayerScreen` is currently mounted and active.
///
/// When a video is playing locally on this device, the ambient "Playing on
/// (Device Name)" banner and offline target indicators must not appear in the
/// player overlay.
class LocalPlaybackNotifier extends Notifier<bool> {
  final bool _initial;
  int _activeCount = 0;

  LocalPlaybackNotifier([this._initial = false]) {
    if (_initial) {
      _activeCount = 1;
    }
  }

  @override
  bool build() => _initial;

  // `PlayerScreen` calls these from microtasks scheduled in `initState` and
  // `dispose`. When the whole `ProviderScope` goes away in the same frame as
  // the screen, the notifier is already disposed by the time they run, and
  // writing `state` would throw `UnmountedRefException` into whichever zone
  // scheduled the microtask. There is nothing left to track by then.

  void acquire() {
    if (!ref.mounted) return;
    _activeCount++;
    if (!state) {
      state = true;
    }
  }

  void release() {
    if (!ref.mounted) return;
    if (_activeCount > 0) {
      _activeCount--;
    }
    if (_activeCount == 0 && state) {
      state = false;
    }
  }

  void setActive(bool active) {
    if (!ref.mounted) return;
    if (active) {
      if (_activeCount == 0) {
        _activeCount = 1;
      }
      state = true;
    } else {
      _activeCount = 0;
      state = false;
    }
  }
}

final localPlaybackActiveProvider =
    NotifierProvider<LocalPlaybackNotifier, bool>(LocalPlaybackNotifier.new);
