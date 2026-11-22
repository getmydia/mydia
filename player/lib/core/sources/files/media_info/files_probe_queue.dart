/// Reads stream details for a files library in the background after a scan,
/// on desktop only, one file at a time and never during playback.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../media_session/playing_source.dart';
import '../../../player/platform_features.dart';
import '../../source.dart';
import '../../sources_providers.dart' show mediaSourceProvider;
import '../files_media_source.dart';
import '../files_providers.dart' show filesMediaInfoCacheProvider;
import '../peer_files_sources.dart' show isPeerFilesSource;

/// How far the background read of a source's files has got.
@immutable
class ProbeProgress {
  const ProbeProgress({this.running = false, this.done = 0, this.total = 0});

  final bool running;

  /// Files handled in this run, read or not.
  final int done;
  final int total;
}

/// Whether this platform reads file details in the background. Overridden
/// in tests.
final filesProbeDesktopProvider = Provider<bool>(
  (_) => PlatformFeatures.isDesktop,
);

/// How often a waiting queue checks whether playback has ended. Overridden
/// in tests.
final filesProbeIdlePollProvider = Provider<Duration>(
  (_) => const Duration(seconds: 5),
);

final filesProbeQueueProvider =
    NotifierProvider.family<FilesProbeQueue, ProbeProgress, SourceId>(
      FilesProbeQueue.new,
    );

class FilesProbeQueue extends Notifier<ProbeProgress> {
  FilesProbeQueue(this.sourceId);

  final SourceId sourceId;
  final _pending = Queue<String>();

  /// Whether the loop runs; it clears this itself when it ends. [_running]
  /// is its future, which a caller joining the run is handed, and is stale
  /// once [_looping] is false.
  var _looping = false;
  Future<void>? _running;
  var _done = 0;
  var _total = 0;

  /// Bumped by each [enqueueStale], which replaces the list being counted.
  var _list = 0;

  @override
  ProbeProgress build() => const ProbeProgress();

  /// Queues every indexed file whose cached details are missing or stale,
  /// in place of whatever was still waiting, and starts reading them unless
  /// a run is already going. Does nothing off desktop, for a lent library,
  /// or without the cache to keep results in. The returned future ends with
  /// the run and never fails.
  Future<void> enqueueStale() {
    if (!ref.read(filesProbeDesktopProvider)) return Future.value();
    final media = _activeMedia();
    final cache = ref.read(filesMediaInfoCacheProvider);
    if (media == null || cache == null || isPeerFilesSource(media.source)) {
      return Future.value();
    }
    final account = media.source.account.id;
    final stale = [
      for (final file in media.index.files().values)
        if (cache.get(account, file) == null) file.key,
    ];
    if (_looping && stale.isEmpty) {
      // Nothing new to count: keep the numbers until the read in flight
      // reports, instead of showing a run of 0 of 0.
      _pending.clear();
      _report();
      return _running ?? Future.value();
    }
    _pending
      ..clear()
      ..addAll(stale);
    _list++;
    _done = 0;
    _total = _pending.length;
    if (_looping) {
      _report();
      return _running ?? Future.value();
    }
    if (_pending.isEmpty) {
      _report();
      return Future.value();
    }
    _looping = true;
    _report();
    return _running = _run();
  }

  /// This source's [FilesMediaSource] while it is still alive, else null.
  FilesMediaSource? _activeMedia() {
    try {
      final media = ref.read(mediaSourceProvider(sourceId));
      if (media is! FilesMediaSource) return null;
      if (!FilesMediaSource.activeSources.contains(media)) return null;
      return media;
    } catch (e) {
      debugPrint('[FilesProbeQueue] $sourceId: source unavailable: $e');
      return null;
    }
  }

  void _report() {
    if (!ref.mounted) return;
    state = ProbeProgress(running: _looping, done: _done, total: _total);
  }

  Future<void> _run() async {
    try {
      while (_pending.isNotEmpty) {
        while (ref.mounted && ref.read(playingSourceProvider).current != null) {
          // A source removed during playback ends the run now, not after it.
          if (_activeMedia() == null) {
            debugPrint(
              '[FilesProbeQueue] $sourceId: source gone while '
              'waiting, ${_pending.length} files left unread',
            );
            _pending.clear();
            return;
          }
          await Future<void>.delayed(ref.read(filesProbeIdlePollProvider));
        }
        if (!ref.mounted) return;
        final media = _activeMedia();
        if (media == null) {
          debugPrint(
            '[FilesProbeQueue] $sourceId: source gone, '
            '${_pending.length} files left unread',
          );
          _pending.clear();
          return;
        }
        final key = _pending.removeFirst();
        // A replaced list starts its count over; a read from the old one
        // that ends now is not part of it.
        final list = _list;
        await _probe(media, key);
        if (!ref.mounted) return;
        if (_list == list) _done++;
        _report();
      }
    } catch (e) {
      debugPrint('[FilesProbeQueue] $sourceId: stopped: $e');
      _pending.clear();
    } finally {
      // Cleared here and not in a later callback, so an enqueue that comes
      // right after starts a new run instead of joining this ended one.
      _looping = false;
      _report();
    }
  }

  /// Reads [key] unless it is gone from the index or was read meanwhile
  /// (an opened Media Info panel). A failure is not retried in this run.
  Future<void> _probe(FilesMediaSource media, String key) async {
    final file = media.indexedFile(key);
    if (file == null) return;
    final cache = ref.read(filesMediaInfoCacheProvider);
    if (cache?.get(media.source.account.id, file) != null) return;
    try {
      await media.probeFileKey(key);
    } catch (e) {
      debugPrint('[FilesProbeQueue] $key not read: $e');
    }
  }
}
