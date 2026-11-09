/// Progress for a source with no server to tell: positions go to the local
/// store under the item's progress key, and the source's lists are told when
/// what they show could have changed.
library;

import '../../domain/sources/item.dart';
import '../p2p/peer_sync_store.dart';
import '../playback/local_playback_progress.dart';
import '../playback/playback_progress_store.dart';
import 'periodic_progress_reporter.dart';
import 'progress_service.dart';

/// Where a stored position leaves an item, as lists show it.
enum _Standing { notStarted, inProgress, watched }

class LocalProgressReporter extends PeriodicProgressReporter {
  LocalProgressReporter({
    required this.store,
    required this.item,
    required this.onChanged,
    this.resumeMinSeconds = 30,
    this.watchedFraction = ProgressService.watchedThreshold,
    this.currentItem,
    this.syncStore,
    this.syncKeyFor,
    this.onSyncWrite,
    DateTime Function()? clock,
    super.interval,
  }) : _clock = clock ?? DateTime.now;

  final PlaybackProgressStore store;
  final PeerSyncStore? syncStore;
  final String? Function(ItemRef item)? syncKeyFor;
  final void Function()? onSyncWrite;

  /// The item playback started on.
  final ItemRef item;

  /// What [item] is called now, read on every save: a files library can
  /// move an item to a new id (a match landing) while it plays.
  final ItemRef Function()? currentItem;

  ItemRef get _item => currentItem?.call() ?? item;

  /// Called when playback stops, and when a save moves the item into or out
  /// of Continue Watching or across the watched line. Not on every periodic
  /// save: telling the lists rebuilds them behind the player.
  final Future<void> Function() onChanged;

  /// Below this many seconds an item is not under way.
  final int resumeMinSeconds;

  /// At or past this fraction of the duration an item is watched.
  final double watchedFraction;

  final DateTime Function() _clock;

  String get _mediaType => _item.kind == ItemKind.episode ? 'episode' : 'movie';

  _Standing _standing(int position, int duration) {
    if (duration > 0 && position / duration >= watchedFraction) {
      return _Standing.watched;
    }
    return position < resumeMinSeconds
        ? _Standing.notStarted
        : _Standing.inProgress;
  }

  _Standing _stored() {
    final syncKey = syncKeyFor?.call(_item);
    if (syncStore != null && syncKey != null) {
      final rec = syncStore!.watchRecord(syncKey);
      if (rec != null) {
        if (rec.watched) return _Standing.watched;
        final pos = rec.positionSeconds ?? 0;
        final dur = rec.durationSeconds ?? 0;
        return _standing(pos, dur);
      }
    }
    final p = store.get(progressKey(_item));
    return p == null
        ? _Standing.notStarted
        : _standing(p.positionSeconds, p.durationSeconds);
  }

  /// Saves the position; returns whether the item's standing changed.
  Future<bool> _save(int positionSeconds, int durationSeconds) async {
    final before = _stored();
    await recordLocalProgress(
      store: store,
      item: _item,
      mediaType: _mediaType,
      position: Duration(seconds: positionSeconds),
      duration: Duration(seconds: durationSeconds),
      now: _clock(),
    );
    final syncKey = syncKeyFor?.call(_item);
    if (syncStore != null && syncKey != null) {
      await syncStore!.recordProgress(
        syncKey,
        positionSeconds: positionSeconds,
        durationSeconds: durationSeconds,
        watchedFraction: watchedFraction,
        nowMs: _clock().millisecondsSinceEpoch,
      );
      onSyncWrite?.call();
    }
    return _stored() != before;
  }

  @override
  Future<void> sendProgress({
    required int positionSeconds,
    required int durationSeconds,
    required bool paused,
  }) async {
    if (await _save(positionSeconds, durationSeconds)) await onChanged();
  }

  /// The position past the threshold is what makes an item watched, and
  /// [sendProgress] has stored it.
  @override
  Future<void> sendWatched() async {}

  @override
  Future<void> sendStopped({
    required int positionSeconds,
    required int durationSeconds,
  }) async {
    await _save(positionSeconds, durationSeconds);
    await onChanged();
  }
}
