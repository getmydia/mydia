import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import '../cache/watcher_registry.dart' show invalidatorProvider;
import '../sources/capabilities.dart';
import '../sources/media_source.dart';
import '../sources/sources_providers.dart';
import 'playback_progress_store.dart';

/// Keep-alive: the store is opened once and read from the player screen on
/// every playback start, including offline, where nothing else is available
/// to rebuild it.
final playbackProgressStoreProvider =
    FutureProvider<PlaybackProgressStore>((ref) async {
  final box = await Hive.openBox<Map<dynamic, dynamic>>(
      HivePlaybackProgressStore.boxName);
  return HivePlaybackProgressStore(box);
});

/// Pushes positions recorded offline to their sources: once at startup,
/// whenever the app resumes, and whenever a source comes back into reach.
final sourceProgressFlushProvider = Provider<void>((ref) {
  if (kIsWeb) return;
  var inFlight = false;

  Future<void> run() async {
    if (inFlight) return;
    inFlight = true;
    try {
      final invalidator = ref.read(invalidatorProvider);
      final store = await ref.read(playbackProgressStoreProvider.future);
      final synced = await flushSourceProgress(
        store: store,
        syncFor: (id) => ref.read(mediaSourceProvider(id))?.as<ProgressSync>(),
        reachable: (id) {
          final status = ref.read(mediaSourceProvider(id))?.connection;
          return status != null &&
              status != SourceConnectionStatus.unreachable &&
              status != SourceConnectionStatus.connecting;
        },
        now: DateTime.now(),
        invalidate: invalidator.invalidate,
      );
      if (synced > 0) {
        debugPrint('[sourceProgressFlush] Synced $synced offline position(s)');
      }
    } catch (e) {
      debugPrint('[sourceProgressFlush] $e');
    } finally {
      inFlight = false;
    }
  }

  final lifecycle = AppLifecycleListener(onResume: () => unawaited(run()));
  ref.onDispose(lifecycle.dispose);

  for (final source in ref.watch(thirdPartySourcesProvider)) {
    final media = ref.watch(mediaSourceProvider(source.id));
    if (media == null) continue;
    void onStatus() {
      final status = media.statusListenable.value;
      if (status != SourceConnectionStatus.unreachable &&
          status != SourceConnectionStatus.connecting) {
        unawaited(run());
      }
    }

    media.statusListenable.addListener(onStatus);
    ref.onDispose(() => media.statusListenable.removeListener(onStatus));
  }
  unawaited(run());
});
