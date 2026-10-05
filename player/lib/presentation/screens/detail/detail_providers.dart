/// Detail views and actions by target. The Mydia branch wraps the existing
/// GraphQL controllers; nothing here changes how they fetch or invalidate.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/graphql/watch/query_key.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/sources/item.dart';
import '../episode/episode_detail_controller.dart';
import '../movie/movie_detail_controller.dart';
import '../show/season_episodes_controller.dart';
import '../show/show_detail_controller.dart';
import 'detail_actions.dart';
import 'mydia_detail_mapping.dart';
import 'source_detail_controllers.dart';

/// Opens the player at [location] from a detail screen. A source item's
/// progress changes while playing, so once the player pops everything that
/// shows it is refetched. Mydia targets keep the player's own invalidation
/// rules.
Future<void> pushPlayer(
  BuildContext context,
  WidgetRef ref,
  DetailTarget target,
  String location,
) async {
  // Capture before the await: the screen can be gone when the player pops.
  final container = ref.container;
  await context.push(location);
  // The screen under the player is paused while covered, and invalidating a
  // paused provider flushes it in the build that resumes it, which Riverpod
  // rejects. Let that frame finish first.
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return;
  if (target case SourceTarget(:final ref)) {
    invalidateSourceDetailWrites(container, ref);
  }
}

typedef SeasonKey = ({DetailTarget show, int seasonNumber});

final movieViewProvider =
    Provider.autoDispose.family<AsyncValue<MovieView>, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) =>
      ref.watch(movieDetailControllerProvider(id)).whenData(movieViewFromMydia),
    SourceTarget(ref: final item) => ref.watch(sourceMovieProvider(item)),
  },
);

final showViewProvider =
    Provider.autoDispose.family<AsyncValue<ShowView>, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) =>
      ref.watch(showDetailControllerProvider(id)).whenData(showViewFromMydia),
    SourceTarget(ref: final item) => ref.watch(sourceShowProvider(item)),
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
    case SourceTarget(ref: final item):
      return ref.watch(
        sourceSeasonProvider((show: item, seasonNumber: key.seasonNumber)),
      );
  }
});

final episodeViewProvider =
    Provider.autoDispose.family<AsyncValue<EpisodeView>, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) => ref
        .watch(episodeDetailControllerProvider(id))
        .whenData(episodeViewFromMydiaDetail),
    SourceTarget(ref: final item) => ref.watch(sourceEpisodeProvider(item)),
  },
);

final movieActionsProvider =
    Provider.autoDispose.family<MovieActions, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) => MydiaMovieActions(ref, id),
    SourceTarget(ref: final item) =>
      ref.read(sourceMovieProvider(item).notifier),
  },
);

final showActionsProvider =
    Provider.autoDispose.family<ShowActions, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) => MydiaShowActions(ref, id),
    SourceTarget(ref: final item) =>
      ref.read(sourceShowProvider(item).notifier),
  },
);

final seasonActionsProvider =
    Provider.autoDispose.family<SeasonActions, SeasonKey>(
  (ref, key) => switch (key.show) {
    MydiaTarget(:final id) => MydiaSeasonActions(ref, id, key.seasonNumber),
    SourceTarget(ref: final item) => ref.read(
        sourceSeasonProvider((show: item, seasonNumber: key.seasonNumber))
            .notifier,
      ),
  },
);

final episodeActionsProvider =
    Provider.autoDispose.family<EpisodeActions, DetailTarget>(
  (ref, target) => switch (target) {
    MydiaTarget(:final id) => MydiaEpisodeActions(ref, id),
    SourceTarget(ref: final item) =>
      ref.read(sourceEpisodeProvider(item).notifier),
  },
);

/// The freshness banner's keys.
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
      SourceTarget(:final ref) => [
          SourceKeys.item(ref),
          if (ref.kind == ItemKind.show) SourceKeys.children(ref),
        ],
    };
