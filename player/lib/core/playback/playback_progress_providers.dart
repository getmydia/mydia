import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import '../auth/auth_status.dart';
import '../graphql/graphql_provider.dart';
import '../player/progress_service.dart';
import 'playback_progress_store.dart';

/// Keep-alive: the store is opened once and read from the player screen on
/// every playback start, including offline, where nothing else is available
/// to rebuild it.
final playbackProgressStoreProvider =
    FutureProvider<PlaybackProgressStore>((ref) async {
  final box = await Hive.openBox<Map>(HivePlaybackProgressStore.boxName);
  return HivePlaybackProgressStore(box);
});

/// Pushes offline-recorded positions once the app is back online.
///
/// Watches the same auth state the player screen reads. Only the transition
/// into `authenticated` triggers a flush; a flush that fails leaves its
/// records queued for the next transition.
final progressFlushProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<AuthStatus>>(authStateProvider, (previous, next) {
    final wasOffline = previous?.value == AuthStatus.offlineMode;
    final isOnline = next.value == AuthStatus.authenticated;
    if (!wasOffline || !isOnline) return;

    unawaited(_flush(ref));
  });
});

Future<void> _flush(Ref ref) async {
  try {
    final store = await ref.read(playbackProgressStoreProvider.future);
    final client = await ref.read(asyncGraphqlClientProvider.future);
    final synced = await flushUnsyncedProgress(
      store: store,
      progressService: ProgressService(client),
      now: DateTime.now(),
    );
    if (synced > 0) {
      debugPrint('[PlaybackProgress] Synced $synced offline position(s)');
    }
  } catch (e) {
    debugPrint('[PlaybackProgress] Deferring flush: $e');
  }
}
