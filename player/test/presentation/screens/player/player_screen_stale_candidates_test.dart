// Regression coverage for playback pinned to a file that no longer exists.
//
// A quality upgrade — or a manual delete-and-redownload — replaces an
// episode's (or movie's) file: a new `media_files` row is written and the
// old one is deleted. `_fetchStreamingCandidates` asks the server about the
// *file* the route names (`('file', fileId)`), not the media item, so a
// route built before that swap still carries the deleted file's id into that
// query. The server answers an id it does not recognize with a GraphQL
// error rather than throwing, and `_initializePlayer` treats that specific
// shape of failure — `graphqlErrors` present, no `linkException` — as "this
// file is gone": it re-asks by media item and lets the server rank a file
// that still exists, instead of handing the dead id on to
// `StartStreamingSession`.
//
// That mattered because the direct-play branch takes its id from
// `widget.fileId` (see `player_honors_selected_file_test.dart`), and without
// this fallback a deleted file would either stay pinned there forever or —
// pre-dating that fix — come from a *media-item*-keyed candidates cache,
// stale or not. Either way the failure mode was a permanent,
// restart-surviving black screen: a p2p direct stream for a deleted file
// answers "media file not found in database", no bytes ever arrive, and the
// timeline runs happily off an equally stale cached duration so nothing
// looks wrong.
//
// The second test below keeps the other half of master's original
// guarantee: `FetchPolicy.networkOnly` on this query is still load-bearing,
// now pinned to the `('file', <fileId>)` cache key the screen actually reads
// instead of the old `('movie', ...)` one. A one-shot `client.query()`
// defaults to `FetchPolicy.cacheFirst` over a Hive store on disk, so a
// regression back to that default would go undetected by any test that only
// checks the *outcome* of a request, cache hit or miss.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/graphql/queries/streaming_candidates.graphql.dart';

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

/// The request `_fetchStreamingCandidates` issues for [fileId] on the
/// harness's movie.
Request _fileCandidatesRequest(String fileId) => Request(
      operation: const Operation(
        document: documentNodeQueryStreamingCandidates,
      ),
      variables: Variables$Query$StreamingCandidates(
        contentType: 'file',
        id: fileId,
      ).toJson(),
    );

void main() {
  testWidgets(
      'a file the server has rejected falls back to the server-ranked file '
      'for the media item', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // `file-old` is what the route still names. The server has since
    // dropped it — a quality upgrade replaced the row — and says so with a
    // GraphQL error instead of guessing, which is what the fallback below
    // keys off. The re-ask by media item is what the server ranks highest
    // today.
    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      graphqlErrorResponse('file not found'),
      streamingCandidatesResponse(
        duration: 5400,
        directPlay: true,
        fileId: 'file-new',
      ),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container, fileId: 'file-old');
    await pumpUntil(
      tester,
      () => proxyService.directStreamFileIds.isNotEmpty,
    );

    expect(
      proxyService.directStreamFileIds,
      contains('file-new'),
      reason: 'once the server rejects the route\'s file id, the file to '
          'play has to come from the server\'s re-ranked answer for the '
          'media item, not the id the route still carries',
    );
    expect(
      proxyService.directStreamFileIds,
      isNot(contains('file-old')),
      reason: 'file-old no longer exists; streaming it is the black screen '
          'this fallback exists to avoid',
    );

    // Pins the mechanism, not just the outcome: the first call has to ask
    // about the rejected file specifically, and only the retry may ask by
    // media item. Third/fourth scripted calls, matching the response order
    // above (detail, segments, then the two candidates calls) — `StubLink`
    // is index-based, the same ordering every other PlayerScreen test
    // relies on.
    expect(link.requests[2].variables['contentType'], 'file');
    expect(link.requests[2].variables['id'], 'file-old');
    expect(link.requests[3].variables['contentType'], 'movie');
    expect(link.requests[3].variables['id'], 'movie-1');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('the candidates query reaches the network on every playback',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // The install has played this exact file before. Its cached answer is
    // deliberately stale (`file-old`) so a regression to `cacheFirst` would
    // both skip the network call the assertion below checks for, and hand
    // back an id nothing downstream expects.
    final cache = GraphQLCache(store: InMemoryStore());
    cache.writeQuery(
      _fileCandidatesRequest('file-1'),
      data: streamingCandidatesResponse(
        duration: 5400,
        directPlay: true,
        fileId: 'file-old',
      ),
      broadcast: false,
    );

    // Guard against a false pass. If the seed above did not land under the
    // key the screen actually reads, the query would miss the cache, go to
    // the network for unrelated reasons, and this test would go green while
    // the bug it exists to catch was fully intact.
    expect(
      cache.readQuery(_fileCandidatesRequest('file-1')),
      isNotNull,
      reason: 'the cache must genuinely hold a stale entry for this query, '
          'otherwise the assertion below proves nothing',
    );

    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      // What the server says today, for the same file the cache answered.
      streamingCandidatesResponse(
        duration: 5400,
        directPlay: true,
        fileId: 'file-1',
      ),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: castManager,
      proxyService: proxyService,
      cache: cache,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(
      tester,
      () => proxyService.directStreamFileIds.isNotEmpty,
    );

    // Asserting on the transport rather than only on the outcome: it is the
    // difference between "happened to produce the right id" and "actually
    // asked". A cacheFirst policy never reaches the link at all.
    //
    // Identified by its variables rather than by `operation.operationName`,
    // which is null here: that field is optional and only carries a value when
    // the call site passes one, which `_fetchStreamingCandidates` does not.
    // `contentType` is unique to this query among the three the screen issues.
    expect(
      link.requests.where((r) => r.variables.containsKey('contentType')).length,
      1,
      reason: 'a warm cache entry must not stand in for asking the server',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
