/// What a remote `LoadContent` or a pull back to this device needs to know
/// about the item it names, read from the bound Mydia instance.
///
/// The ids in those commands are bare Mydia ids, so they belong to the bound
/// instance until the commands name a source of their own.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/remote/load_content_navigation.dart';
import '../../../core/sources/mydia/bound_mydia.dart';
import '../../../domain/sources/item.dart';
import '../sources/source_browse_providers.dart';
import 'source_detail_mapping.dart';

Future<ItemDetail> _fetchBound(WidgetRef ref, ItemKind kind, String id) {
  final sourceId = ref.read(boundSourceIdProvider);
  if (sourceId == null) throw StateError('No Mydia server');
  final provider = sourceItemProvider(
    ItemRef(sourceId: sourceId, kind: kind, externalId: id),
  );
  return readDetailKeepingAlive(ref,
      provider: provider, future: provider.future);
}

Future<LoadContentTarget> fetchLoadContentMovie(
  WidgetRef ref,
  String id,
) async {
  final movie = await _fetchBound(ref, ItemKind.movie, id);
  return LoadContentTarget(
    files: filesFromVersions(movie.versions),
    title: movie.summary.title,
  );
}

Future<LoadContentTarget> fetchLoadContentEpisode(
  WidgetRef ref,
  String id,
) async {
  final episode = await _fetchBound(ref, ItemKind.episode, id);
  return LoadContentTarget(
    files: filesFromVersions(episode.versions),
    title: episode.summary.title,
    showId: episode.show?.externalId,
    seasonNumber: episode.summary.parentIndex,
  );
}
