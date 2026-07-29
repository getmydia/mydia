import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/invalidation_rules.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../core/graphql/watch/watcher_registry.dart';
import '../../../domain/models/episode.dart';
import '../../../domain/models/progress.dart';
import '../../../graphql/mutations/mark_watched.graphql.dart';

part 'season_episodes_controller.g.dart';

const String seasonEpisodesQuery = r'''
query SeasonEpisodes($showId: ID!, $seasonNumber: Int!) {
  seasonEpisodes(showId: $showId, seasonNumber: $seasonNumber) {
    id
    seasonNumber
    episodeNumber
    title
    overview
    airDate
    runtime
    monitored
    thumbnailUrl
    hasFile
    progress {
      positionSeconds
      durationSeconds
      percentage
      watched
      lastWatchedAt
    }
    files {
      id
      resolution
      codec
      audioCodec
      hdrFormat
      size
      bitrate
      directPlaySupported
      streamUrl
      directPlayUrl
    }
  }
}
''';

List<Episode> _parseEpisodes(Map<String, dynamic> data) {
  return (data['seasonEpisodes'] as List<dynamic>? ?? [])
      .map((e) => Episode.fromJson(e as Map<String, dynamic>))
      // Only episodes with files available in Mydia.
      .where((episode) => episode.hasFile)
      .toList();
}

@riverpod
class SeasonEpisodesController extends _$SeasonEpisodesController {
  late QueryWatcher<List<Episode>> _watcher;

  @override
  Stream<List<Episode>> build({
    required String showId,
    required int seasonNumber,
  }) {
    _watcher = createWatcher<List<Episode>>(
      ref,
      key: QueryKeys.seasonEpisodes(showId, seasonNumber),
      document: gql(seasonEpisodesQuery),
      variables: {'showId': showId, 'seasonNumber': seasonNumber},
      parse: _parseEpisodes,
    );
    return _watcher.stream;
  }

  Future<void> refresh() => _watcher.refetch();

  // ── Watched-status actions (optimistic, revert-on-error) ──────────────
  //
  // Each action mirrors movie_detail_controller's toggleFavorite(): apply the
  // new watched state to the affected episodes immediately (Plex-style, no
  // confirmation), await the mutation, and revert the whole list on failure.
  // On success the optimistic list is kept as-is (no server reconciliation);
  // the next refresh() re-fetches authoritative state from the server.

  /// Marks a single episode watched.
  Future<void> markEpisodeWatched(Episode episode) {
    return _applyWatchedAction(
      affects: (ep) => ep.id == episode.id,
      watched: true,
      options: MutationOptions(
        document: documentNodeMutationMarkEpisodeWatched,
        variables: Variables$Mutation$MarkEpisodeWatched(episodeId: episode.id)
            .toJson(),
      ),
    );
  }

  /// Marks a single episode unwatched (drops its progress row).
  Future<void> markEpisodeUnwatched(Episode episode) {
    return _applyWatchedAction(
      affects: (ep) => ep.id == episode.id,
      watched: false,
      options: MutationOptions(
        document: documentNodeMutationMarkEpisodeUnwatched,
        variables:
            Variables$Mutation$MarkEpisodeUnwatched(episodeId: episode.id)
                .toJson(),
      ),
    );
  }

  /// Marks [episode] and every earlier episode in this season watched.
  ///
  /// The controller is already season-scoped, so "earlier in this season"
  /// reduces to an `episodeNumber <=` comparison on the in-memory list.
  Future<void> markThisAndPreviousWatched(Episode episode) {
    return _applyWatchedAction(
      affects: (ep) => ep.episodeNumber <= episode.episodeNumber,
      watched: true,
      options: MutationOptions(
        document: documentNodeMutationMarkEpisodesUpToWatched,
        variables: Variables$Mutation$MarkEpisodesUpToWatched(
          episodeId: episode.id,
        ).toJson(),
      ),
    );
  }

  /// Marks every episode in the selected season watched.
  Future<void> markSeasonWatched() {
    return _applyWatchedAction(
      affects: (_) => true,
      watched: true,
      options: MutationOptions(
        document: documentNodeMutationMarkSeasonWatched,
        variables: Variables$Mutation$MarkSeasonWatched(
          showId: showId,
          seasonNumber: seasonNumber,
        ).toJson(),
      ),
    );
  }

  /// Marks every episode in the selected season unwatched.
  Future<void> markSeasonUnwatched() {
    return _applyWatchedAction(
      affects: (_) => true,
      watched: false,
      options: MutationOptions(
        document: documentNodeMutationMarkSeasonUnwatched,
        variables: Variables$Mutation$MarkSeasonUnwatched(
          showId: showId,
          seasonNumber: seasonNumber,
        ).toJson(),
      ),
    );
  }

  Future<void> _applyWatchedAction({
    required bool Function(Episode) affects,
    required bool watched,
    required MutationOptions options,
  }) async {
    final snapshot = state.value;
    if (snapshot == null) return;

    // Optimistically reflect the new watched state before the server responds.
    state = AsyncValue.data(applyOptimisticWatched(snapshot, affects, watched));

    try {
      final client = await ref.read(asyncGraphqlClientProvider.future);
      final result = await client.mutate(options);

      if (result.hasException) {
        state = AsyncValue.data(snapshot);
        throw result.exception!;
      }

      // The optimistic state already matches the server's new watched state,
      // so there is nothing to reconcile for the season list. Everything else
      // that shows watched state does need to hear about it.
      await ref.read(invalidatorProvider).invalidate(
            InvalidationRules.watchedChanged(
              showId: showId,
              seasonNumber: seasonNumber,
            ),
          );
    } catch (e) {
      state = AsyncValue.data(snapshot);
      rethrow;
    }
  }

  /// Pure helper: returns a copy of [episodes] with the watched state of every
  /// episode matching [affects] set to [watched]. Marking watched preserves any
  /// existing position/percentage; marking unwatched drops the progress row so
  /// the badge disappears (mirroring the backend's delete-progress semantics).
  static List<Episode> applyOptimisticWatched(
    List<Episode> episodes,
    bool Function(Episode) affects,
    bool watched,
  ) {
    return episodes
        .map((ep) => affects(ep) ? _withWatched(ep, watched) : ep)
        .toList();
  }

  static Episode _withWatched(Episode episode, bool watched) {
    if (!watched) {
      return episode.copyWith(clearProgress: true);
    }

    final existing = episode.progress;
    return episode.copyWith(
      progress: Progress(
        positionSeconds: existing?.positionSeconds ?? 0,
        durationSeconds: existing?.durationSeconds,
        percentage: existing?.percentage ?? 0,
        watched: true,
        lastWatchedAt: existing?.lastWatchedAt,
      ),
    );
  }
}
