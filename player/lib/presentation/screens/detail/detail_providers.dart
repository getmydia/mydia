/// Detail views and actions by target.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/cache/query_key.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/sources/item.dart';
import 'detail_actions.dart';
import 'source_detail_controllers.dart';

/// Opens the player at [location] from a detail screen. A source item's
/// progress changes while playing, so once the player pops everything that
/// shows it is refetched.
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
  invalidateSourceDetailWrites(container, target.ref);
}

typedef SeasonKey = ({DetailTarget show, int seasonNumber});

final movieViewProvider =
    Provider.autoDispose.family<AsyncValue<MovieView>, DetailTarget>(
  (ref, target) => ref.watch(sourceMovieProvider(target.ref)),
);

final showViewProvider =
    Provider.autoDispose.family<AsyncValue<ShowView>, DetailTarget>(
  (ref, target) => ref.watch(sourceShowProvider(target.ref)),
);

final seasonEpisodesViewProvider =
    Provider.autoDispose.family<AsyncValue<List<EpisodeView>>, SeasonKey>(
  (ref, key) => ref.watch(
    sourceSeasonProvider((show: key.show.ref, seasonNumber: key.seasonNumber)),
  ),
);

final episodeViewProvider =
    Provider.autoDispose.family<AsyncValue<EpisodeView>, DetailTarget>(
  (ref, target) => ref.watch(sourceEpisodeProvider(target.ref)),
);

final movieActionsProvider =
    Provider.autoDispose.family<MovieActions, DetailTarget>(
  (ref, target) => ref.read(sourceMovieProvider(target.ref).notifier),
);

final showActionsProvider =
    Provider.autoDispose.family<ShowActions, DetailTarget>(
  (ref, target) => ref.read(sourceShowProvider(target.ref).notifier),
);

final seasonActionsProvider =
    Provider.autoDispose.family<SeasonActions, SeasonKey>(
  (ref, key) => ref.read(
    sourceSeasonProvider((show: key.show.ref, seasonNumber: key.seasonNumber))
        .notifier,
  ),
);

final episodeActionsProvider =
    Provider.autoDispose.family<EpisodeActions, DetailTarget>(
  (ref, target) => ref.read(sourceEpisodeProvider(target.ref).notifier),
);

/// The freshness banner's keys.
List<QueryKey> freshnessKeys(DetailTarget target) => [
      SourceKeys.item(target.ref),
      if (target.ref.kind == ItemKind.show) SourceKeys.children(target.ref),
    ];
