import 'package:flutter/foundation.dart' show debugPrint, debugPrintStack;
import 'package:flutter/widgets.dart' show immutable;

import '../../domain/models/media_file.dart';
import '../player/best_file.dart';
import 'remote_control_intent.dart';

/// Everything `resolveLoadContentRoute` needs beyond the file list itself.
///
/// `title` backs `describe()`'s reporting back to controllers (it falls back
/// to 'Untitled' with nothing supplied); `showId`/`seasonNumber` are what
/// `PlayerScreen._hasNextEpisode`/`_hasPreviousEpisode` gate on — null either
/// one and a remotely-started episode's next/previous-episode capability is
/// silently dead, even though the exact same fetch this type is built from
/// already has both fields on hand. Both are null for a movie, which has
/// neither concept.
@immutable
class LoadContentTarget {
  final List<MediaFile> files;
  final String title;
  final String? showId;
  final int? seasonNumber;

  const LoadContentTarget({
    required this.files,
    required this.title,
    this.showId,
    this.seasonNumber,
  });
}

/// Fetches [LoadContentTarget] for whichever half of a `LoadContentIntent`
/// identifies content — an episode's own files/title/show context, or a
/// movie's. Kept as a function type rather than folded into
/// [resolveLoadContentRoute] directly, so a test can substitute a fake
/// fetcher and assert the resolution *decision* without a GraphQL client at
/// all.
///
/// Deliberately not implemented in this file: a real fetcher reads
/// `movieDetailControllerProvider`/`episodeDetailControllerProvider`, both
/// `presentation/` code, and `core/remote/` never imports `presentation/` —
/// see `RemotePlayerBinding`'s dartdoc in `remote_target_controller.dart` for
/// the same rule applied to the receiver side. `app.dart`'s
/// `_pushLoadContent` and `CastMiniController._pullToLocal`
/// (`presentation/widgets/cast_mini_controller.dart`) each build their own
/// closures against those providers instead.
typedef LoadContentTargetFetcher = Future<LoadContentTarget> Function(
    String id);

/// The `/player/...` route a `LoadContentIntent` should actually land on, or
/// null when nothing here resolves to a playable file.
///
/// This is the target side of the feature's primary use case: a controller
/// on another device said "play this", and this device has to turn that
/// reference into an actual stream against the server it is already paired
/// to. Resolving means fetching the right target — the episode's own,
/// never the show's, when [LoadContentIntent.episodeId] is set — then
/// running the same [pickBestFile] every local Play button uses, so a
/// remote play and a local tap never disagree about which version plays.
/// `title`/`showId`/`seasonNumber` ride along in the returned route's query
/// string exactly as `playerRouteForContinueWatching`
/// (`home_screen.dart:42-68`) already carries them for a local tap, so a
/// remotely-started episode keeps its next/previous-episode capability
/// instead of losing it.
///
/// Runs off an inbound network command (or a local pull — see
/// `CastMiniController._pullToLocal`) with no user-facing error path of its
/// own, so every failure here — a fetch that throws, [pickBestFile]'s own
/// device/network probe throwing — is caught and turned into null rather
/// than left to propagate. The caller's job is only to fall back to the
/// detail screen when this returns null.
Future<String?> resolveLoadContentRoute(
  LoadContentIntent intent,
  double screenWidth, {
  required LoadContentTargetFetcher fetchMovieTarget,
  required LoadContentTargetFetcher fetchEpisodeTarget,
}) async {
  final episodeId = intent.episodeId;

  try {
    final target = episodeId != null
        ? await fetchEpisodeTarget(episodeId)
        : await fetchMovieTarget(intent.mediaItemId);

    final file = await pickBestFile(target.files, screenWidth);
    if (file == null) return null;

    final type = episodeId != null ? 'episode' : 'movie';
    final id = episodeId ?? intent.mediaItemId;

    final query = <String, String>{
      'fileId': file.id,
      'title': target.title,
      'resume': intent.startAt.inSeconds.toString(),
      if (target.showId != null) 'showId': target.showId!,
      if (target.seasonNumber != null)
        'seasonNumber': target.seasonNumber.toString(),
      if (intent.audioTrack != null) 'audioTrack': intent.audioTrack!,
      if (intent.subtitleTrack != null) 'subtitleTrack': intent.subtitleTrack!,
      // Absent means the player's own default (true, i.e. play).
      if (!intent.autoplay) 'autoplay': 'false',
    };

    return Uri(path: '/player/$type/$id', queryParameters: query).toString();
  } catch (error, stackTrace) {
    debugPrint('[LoadContentNavigation] Resolution failed: $error');
    debugPrintStack(stackTrace: stackTrace);
    return null;
  }
}

/// The detail-screen fallback for [intent] — the same "no file chosen yet"
/// destination every other entry point in this app takes (see
/// `home_screen.dart`'s `_handlePlay`) when nothing resolves to a playable
/// file.
String loadContentDetailFallback(LoadContentIntent intent) =>
    intent.episodeId != null
        ? '/episode/${intent.episodeId}'
        : '/movie/${intent.mediaItemId}';

/// Resolves [intent] and hands [push] the destination: the resolved player
/// route, or [loadContentDetailFallback] when nothing resolves. [push] is
/// the one side effect in this function, kept as an injected callback so a
/// test can assert what gets pushed — including the fallback case, which
/// [resolveLoadContentRoute] alone cannot exercise, since returning `null`
/// from that function is the input to this decision, not the decision
/// itself — without mounting a router at all. Real callers wire [push] to
/// `GoRouter.push` (`app.dart`'s `_pushLoadContent`,
/// `CastMiniController._pullToLocal`).
Future<void> pushLoadContentDestination(
  LoadContentIntent intent,
  double screenWidth, {
  required LoadContentTargetFetcher fetchMovieTarget,
  required LoadContentTargetFetcher fetchEpisodeTarget,
  required void Function(String path) push,
}) async {
  final path = await resolveLoadContentRoute(
    intent,
    screenWidth,
    fetchMovieTarget: fetchMovieTarget,
    fetchEpisodeTarget: fetchEpisodeTarget,
  );

  push(path ?? loadContentDetailFallback(intent));
}
