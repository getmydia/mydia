import 'package:flutter/foundation.dart' show debugPrint, debugPrintStack;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `ProviderListenable` is not part of the main entrypoint's exports, the same
// reason `test_utils` reaches here for `Override`.
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../domain/detail/detail_target.dart';
import '../../domain/sources/item.dart';
import '../../presentation/screens/detail/detail_links.dart';
import '../sources/mydia/mydia_instance_id.dart';
import '../sources/source.dart';
import 'remote_control_intent.dart';

/// Awaits an autoDispose provider's first value while holding it open.
///
/// `ref.read(provider.future)` on its own starts the load with no listener
/// attached, so Riverpod disposes the provider before it can emit and the
/// await throws "was disposed during loading state, yet no value could be
/// emitted". Both remote-control resolutions hit that: pulling a session
/// back to this device, and an inbound `LoadContent` from another player,
/// each resolve a detail controller this way, and each failed at the last
/// step with nothing on screen to explain it.
///
/// The subscription is what keeps it alive; closing it in `finally` returns
/// the provider to ordinary autoDispose behavior however the read ends.
Future<T> readDetailKeepingAlive<T>(
  WidgetRef ref, {
  required ProviderListenable<AsyncValue<T>> provider,
  required ProviderListenable<Future<T>> future,
}) async {
  final subscription = ref.listenManual(provider, (_, __) {});
  try {
    return await ref.read(future);
  } finally {
    subscription.close();
  }
}

/// The item a `LoadContentIntent` names, on the instance it arrived through.
///
/// An episode id wins over the media item id. Null when no instance sent it:
/// its id means nothing on any other source, so it is never looked up there.
ItemRef? loadContentItemRef(LoadContentIntent intent) {
  final via = intent.via;
  if (via == null) return null;
  final episodeId = intent.episodeId;
  return episodeId != null
      ? ItemRef(sourceId: via, kind: ItemKind.episode, externalId: episodeId)
      : ItemRef(
          sourceId: via, kind: ItemKind.movie, externalId: intent.mediaItemId);
}

/// The source player route a `LoadContentIntent` should land on, or null when
/// nothing here resolves to a playable file.
///
/// A controller on another device said "play this", and this device turns
/// that reference into a stream on the instance the command came through.
/// Runs off an inbound network command (or a local pull) with no user-facing
/// error path of its own, so every failure is caught and turned into null:
/// the caller falls back to the detail screen.
///
/// `showId` and `seasonNumber` ride along for an episode exactly as a local
/// episode tap carries them, so a remotely started episode keeps its
/// next/previous-episode capability.
Future<String?> resolveLoadContentRoute(
  LoadContentIntent intent, {
  required Future<ItemDetail> Function(ItemRef) fetch,
}) async {
  final ref = loadContentItemRef(intent);
  if (ref == null) return null;

  try {
    final detail = await fetch(ref);
    final fileId =
        detail.summary.defaultVersionId ?? detail.versions.firstOrNull?.id;
    if (fileId == null) return null;

    final isEpisode = ref.kind == ItemKind.episode;
    final showId = isEpisode ? detail.show?.externalId : null;
    final seasonNumber = isEpisode ? detail.summary.parentIndex : null;

    return sourcePlayerLocation(
      ref,
      fileId: fileId,
      title: detail.summary.title,
      extra: {
        'resume': intent.startAt.inSeconds.toString(),
        if (showId != null) 'showId': showId,
        if (seasonNumber != null) 'seasonNumber': '$seasonNumber',
        if (intent.audioTrack != null) 'audioTrack': intent.audioTrack!,
        if (intent.subtitleTrack != null)
          'subtitleTrack': intent.subtitleTrack!,
        // Absent means the player's own default (true, i.e. play).
        if (!intent.autoplay) 'autoplay': 'false',
      },
    );
  } catch (error, stackTrace) {
    debugPrint('[LoadContentNavigation] Resolution failed: $error');
    debugPrintStack(stackTrace: stackTrace);
    return null;
  }
}

/// The detail-screen fallback for [intent], on the instance that sent it.
/// Only meaningful for an intent with a sending instance.
String loadContentDetailFallback(LoadContentIntent intent) =>
    detailLocation(SourceTarget(loadContentItemRef(intent)!));

/// Resolves [intent] and hands [push] the destination: the resolved player
/// route, or [loadContentDetailFallback] when nothing resolves. An intent
/// with no sending instance pushes nothing. [push] is injected so a test can
/// assert what gets pushed without mounting a router.
Future<void> pushLoadContentDestination(
  LoadContentIntent intent, {
  required Future<ItemDetail> Function(ItemRef) fetch,
  required void Function(String path) push,
}) async {
  if (intent.via == null) return;

  final path = await resolveLoadContentRoute(intent, fetch: fetch);
  push(path ?? loadContentDetailFallback(intent));
}

/// Carries out an [intent] that arrived from [peerNodeId].
///
/// A `LoadContent` names an item by an id only its sending instance can
/// resolve. When the sender names its server ([LoadContentIntent
/// .serverInstanceId]) the command is stamped with that local instance, if the
/// instance also lists the peer, and dropped otherwise. An older sender names
/// none, so the first instance that lists the peer is used, or the command is
/// dropped when none does. Everything else goes through untouched.
Future<void> routeRemoteIntent(
  RemoteControlIntent intent,
  String peerNodeId, {
  required Future<List<SourceId>> Function(String nodeId) instancesOf,
  required void Function(RemoteControlIntent) submit,
}) async {
  if (intent is! LoadContentIntent) {
    submit(intent);
    return;
  }

  final candidates = await instancesOf(peerNodeId);
  final wanted = intent.serverInstanceId;
  final via = wanted == null
      ? candidates.firstOrNull
      : candidates
          .where((id) => mydiaInstanceIdOfSource(id) == wanted)
          .firstOrNull;
  if (via == null) {
    debugPrint(wanted == null
        ? '[LoadContentNavigation] No instance lists $peerNodeId, '
            'dropping LoadContent'
        : '[LoadContentNavigation] No local instance $wanted lists '
            '$peerNodeId, dropping LoadContent');
    return;
  }
  submit(intent.withVia(via));
}
