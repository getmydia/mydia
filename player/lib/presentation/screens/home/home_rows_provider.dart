/// Home's state: each in-scope server's cached feeds, built into rows.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/query_key.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/media_source.dart';
import '../../../core/sources/source.dart';
import '../../../domain/sources/library.dart';
import '../sources/source_browse_providers.dart';
import 'home_rows.dart';
import 'home_scope.dart';

final homeRowsProvider = Provider.autoDispose
    .family<HomeRows, HomeScope>((ref, scope) => buildHomeRows([
          for (final source in scope.sources(ref)) _feedsOf(ref, source),
        ]));

HomeFeeds _feedsOf(Ref ref, MediaSource source) {
  final id = source.id;
  final libraries = ref.watch(sourceLibrariesProvider(id));
  return HomeFeeds(
    id: id,
    name: source.displayName,
    continueWatching: ref.watch(sourceContinueWatchingProvider(id)),
    recentlyAdded: ref.watch(sourceRecentlyAddedProvider(id)),
    favorites: ref.watch(sourceFavoritesRowProvider(id)),
    libraries: libraries,
    previews: {
      for (final library
          in libraries.hasValue ? libraries.requireValue : const <Library>[])
        library.ref: ref.watch(sourceLibraryPreviewProvider(library.ref)),
    },
  );
}

/// Every cache key Home reads for [ids], for the freshness header.
List<QueryKey> homeQueryKeys(Iterable<SourceId> ids) => [
      for (final id in ids) ...[
        SourceKeys.libraries(id),
        SourceKeys.continueWatching(id),
        SourceKeys.recentlyAdded(id),
        SourceKeys.favoritesRow(id),
      ],
    ];

/// Refetches every feed Home reads for [ids]. Completes when the libraries
/// have answered, so the pull-to-refresh indicator stops then.
Future<void> refreshHome(WidgetRef ref, Iterable<SourceId> ids) async {
  for (final id in ids) {
    ref.invalidate(sourceContinueWatchingProvider(id));
    ref.invalidate(sourceRecentlyAddedProvider(id));
    ref.invalidate(sourceFavoritesRowProvider(id));
    ref.invalidate(sourceLibrariesProvider(id));
  }
  ref.invalidate(sourceLibraryPreviewProvider);
  await Future.wait([
    for (final id in ids)
      ref.read(sourceLibrariesProvider(id).future).then<void>((_) {},
          // The screen shows the error; the indicator only has to stop.
          onError: (Object _) {}),
  ]);
}
