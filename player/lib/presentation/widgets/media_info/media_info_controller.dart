import 'package:gql/ast.dart' show DocumentNode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../../../core/graphql/graphql_provider.dart';
import '../../../core/graphql/watch/schema_downgrade.dart';
import '../../../core/sources/mydia/mydia_media_info.dart';
import '../../../domain/models/media_stream.dart';
import '../../../graphql/queries/media_info.graphql.dart';
import 'media_info_sheet.dart';

export '../../../core/sources/mydia/mydia_media_info.dart'
    show mediaFileInfoFromJson;

typedef MediaInfoArgs = ({String id, MediaInfoTarget target});

/// Fetches the files and per-stream detail for one movie or episode.
///
/// A new player can meet an older self-hosted server that does not define the
/// stream fields, so a rejected query retries once with the legacy document.
/// The panel then shows the same "not captured yet" state it shows for a file
/// the server-side backfill has not reached.
final mediaInfoProvider =
    FutureProvider.family<List<MediaFileInfo>, MediaInfoArgs>(
        (ref, args) async {
  final client = ref.watch(graphqlClientProvider);
  if (client == null) {
    throw Exception('GraphQL client not available');
  }

  final document = args.target == MediaInfoTarget.movie
      ? documentNodeQueryMovieMediaInfo
      : documentNodeQueryEpisodeMediaInfo;

  final fallback = args.target == MediaInfoTarget.movie
      ? documentNodeQueryMovieMediaInfoLegacy
      : documentNodeQueryEpisodeMediaInfoLegacy;

  Future<QueryResult<Object?>> run(DocumentNode doc) {
    return client.query(
      QueryOptions(
        document: doc,
        variables: {'id': args.id},
        fetchPolicy: FetchPolicy.networkOnly,
      ),
    );
  }

  var result = await run(document);

  // Only an unknown-field rejection means the server predates these fields.
  // Retrying on any exception would mask a network, auth or server error by
  // re-running the narrower query and returning partial data as if it were
  // whole. Same gate QueryWatcher uses for its own schema downgrade.
  if (result.hasException && isUnknownFieldError(result.exception!)) {
    result = await run(fallback);
  }
  if (result.hasException) {
    throw result.exception!;
  }

  final root = args.target == MediaInfoTarget.movie ? 'movie' : 'episode';
  final data = result.data?[root] as Map<String, dynamic>?;
  final files = (data?['files'] as List<dynamic>? ?? const []);

  return files
      .cast<Map<String, dynamic>>()
      .map(mediaFileInfoFromJson)
      .toList(growable: false);
});
