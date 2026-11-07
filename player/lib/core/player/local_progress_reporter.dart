/// Progress for a source with no server to tell: positions go to the local
/// store under the item's progress key, and the source's lists are told.
library;

import '../../domain/sources/item.dart';
import '../playback/playback_progress_store.dart';
import 'periodic_progress_reporter.dart';

class LocalProgressReporter extends PeriodicProgressReporter {
  LocalProgressReporter({
    required this.store,
    required this.item,
    required this.onSaved,
    DateTime Function()? clock,
    super.interval,
  }) : _clock = clock ?? DateTime.now;

  final PlaybackProgressStore store;
  final ItemRef item;

  /// Called after every save, so lists showing resume and watched state
  /// refresh.
  final Future<void> Function() onSaved;
  final DateTime Function() _clock;

  String get _mediaType => item.kind == ItemKind.episode ? 'episode' : 'movie';

  Future<void> _save(int positionSeconds, int durationSeconds) async {
    await recordLocalProgress(
      store: store,
      item: item,
      mediaType: _mediaType,
      position: Duration(seconds: positionSeconds),
      duration: Duration(seconds: durationSeconds),
      now: _clock(),
    );
    await onSaved();
  }

  @override
  Future<void> sendProgress({
    required int positionSeconds,
    required int durationSeconds,
    required bool paused,
  }) =>
      _save(positionSeconds, durationSeconds);

  /// The position past the threshold is what makes an item watched, and
  /// [sendProgress] has stored it.
  @override
  Future<void> sendWatched() async {}

  @override
  Future<void> sendStopped({
    required int positionSeconds,
    required int durationSeconds,
  }) =>
      _save(positionSeconds, durationSeconds);
}
