/// Detail views and actions by target. The Mydia branch wraps the existing
/// GraphQL controllers; nothing here changes how they fetch or invalidate.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/graphql/watch/query_key.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../episode/episode_detail_controller.dart';
import '../movie/movie_detail_controller.dart';
import '../show/season_episodes_controller.dart';
import '../show/show_detail_controller.dart';
import 'detail_actions.dart';
import 'mydia_detail_mapping.dart';

typedef SeasonKey = ({DetailTarget show, int seasonNumber});

final movieViewProvider =
    Provider.autoDispose.family<AsyncValue<MovieView>, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) =>
      ref.watch(movieDetailControllerProvider(id)).whenData(movieViewFromMydia),
  },
);

final showViewProvider =
    Provider.autoDispose.family<AsyncValue<ShowView>, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) =>
      ref.watch(showDetailControllerProvider(id)).whenData(showViewFromMydia),
  },
);

final seasonEpisodesViewProvider = Provider.autoDispose
    .family<AsyncValue<List<EpisodeView>>, SeasonKey>((ref, key) {
  switch (key.show) {
    case MydiaTarget(:final id):
      final show = ref.watch(showDetailControllerProvider(id)).value;
      return ref
          .watch(
            seasonEpisodesControllerProvider(
              showId: id,
              seasonNumber: key.seasonNumber,
            ),
          )
          .whenData(
            (episodes) => [
              for (final e in episodes) episodeViewFromMydia(e, show: show),
            ],
          );
  }
});

final episodeViewProvider =
    Provider.autoDispose.family<AsyncValue<EpisodeView>, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) => ref
        .watch(episodeDetailControllerProvider(id))
        .whenData(episodeViewFromMydiaDetail),
  },
);

final movieActionsProvider =
    Provider.autoDispose.family<MovieActions, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) => MydiaMovieActions(ref, id),
  },
);

final showActionsProvider =
    Provider.autoDispose.family<ShowActions, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) => MydiaShowActions(ref, id),
  },
);

final seasonActionsProvider =
    Provider.autoDispose.family<SeasonActions, SeasonKey>(
  (ref, key) => switch (key.show) {
    MydiaTarget(:final id) => MydiaSeasonActions(ref, id, key.seasonNumber),
  },
);

final episodeActionsProvider =
    Provider.autoDispose.family<EpisodeActions, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) => MydiaEpisodeActions(ref, id),
  },
);

/// The freshness banner's keys. Only Mydia's watchers report freshness.
List<QueryKey> freshnessKeys(DetailTarget target, {int? seasonNumber}) =>
    switch (target) {
      MydiaTarget(kind: DetailKind.movie, :final id) => [
          QueryKeys.movieDetail(id),
        ],
      MydiaTarget(kind: DetailKind.show || DetailKind.season, :final id) => [
          QueryKeys.showDetail(id),
          if (seasonNumber != null) QueryKeys.seasonEpisodes(id, seasonNumber),
        ],
      MydiaTarget(kind: DetailKind.episode, :final id) => [
          QueryKeys.episodeDetail(id),
        ],
    };
