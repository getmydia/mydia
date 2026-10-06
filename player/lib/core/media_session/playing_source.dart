import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sources/source.dart';

/// Names the instance that owns the item the player screen is playing.
///
/// A plain holder rather than a `Notifier`: the screen claims in `initState`
/// and releases in `dispose`, where Riverpod forbids writing provider state,
/// and the one reader (the media session bridge) polls it on each refresh.
///
/// Ownership mirrors `NowPlayingPublisher`: Flutter mounts a new screen before
/// it disposes the old one, so the old screen's late [release] must not clear
/// what the new screen claimed.
class PlayingSource {
  Object? _owner;
  SourceId? _id;

  /// The instance that owns what is playing, or null when no screen is.
  SourceId? get current => _id;

  void claim(Object owner, SourceId id) {
    _owner = owner;
    _id = id;
  }

  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _id = null;
  }
}

final playingSourceProvider = Provider<PlayingSource>((ref) => PlayingSource());
