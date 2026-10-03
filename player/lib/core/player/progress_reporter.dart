/// What the player screen asks of whatever records viewing progress on a
/// server.
library;

import 'package:media_kit/media_kit.dart';

import 'stream_timeline.dart';

abstract interface class ProgressReporter {
  /// Maps player positions to real ones; a windowed stream starts late.
  StreamTimeline get timeline;
  set timeline(StreamTimeline value);

  /// Starts periodic reporting for [player].
  void start(Player player,
      {required String mediaType, required String mediaId});

  /// Reports the current position now. [mediaType] and [mediaId] name the
  /// item being credited, which during a switch is not the one taking over.
  Future<void> save(Player player,
      {required String mediaType, required String mediaId});

  /// Past the watched threshold.
  bool isWatched(Player player);

  void stopSync();
  void dispose();
}
