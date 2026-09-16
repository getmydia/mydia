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

  void acquire() {
    _activeCount++;
    if (!state) {
      state = true;
    }
  }

  void release() {
    if (_activeCount > 0) {
      _activeCount--;
    }
    if (_activeCount == 0 && state) {
      state = false;
    }
  }

  void setActive(bool active) {
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
