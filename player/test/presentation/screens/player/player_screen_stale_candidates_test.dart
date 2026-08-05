// Regression coverage for playback pinned to a file that no longer exists.
//
// `StreamingCandidates` is keyed by *content* id, never by file id, so its
// cache entry outlives the file it describes. Replace an episode's file — by
// hand, or through an automatic quality upgrade, which writes a new
// `media_files` row and deletes the old one — and the entry is left naming a
// `fileId` the server has since dropped.
//
// That mattered because the direct-play branch takes its id from this response
// rather than from the route, and because a one-shot `client.query()` defaults
// to `FetchPolicy.cacheFirst` over a Hive store on disk. The result was a
// permanent, restart-surviving black screen: the p2p direct stream answered
// "media file not found in database", no bytes ever arrived, and the timeline
// ran happily off the equally stale cached duration so nothing looked wrong.
//
// The fix is `fetchPolicy: FetchPolicy.networkOnly` on that query. This test
// pins it by warming the cache with a stale answer and proving playback still
// goes where the *server* says, not where the cache does.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/graphql/queries/streaming_candidates.graphql.dart';

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

/// The request `_fetchStreamingCandidates` issues for the harness's movie.
Request _candidatesRequest() => Request(
      operation: const Operation(
        document: documentNodeQueryStreamingCandidates,
      ),
      variables: Variables$Query$StreamingCandidates(
        contentType: 'movie',
        id: 'movie-1',
      ).toJson(),
    );

void main() {
  testWidgets('a warm candidates cache cannot pin playback to a deleted file',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // The install has played this title before, back when it was a different
    // file. `file-old` is gone from the server now.
    final cache = GraphQLCache(store: InMemoryStore());
    cache.writeQuery(
      _candidatesRequest(),
      data: streamingCandidatesResponse(
        duration: 5400,
        directPlay: true,
        fileId: 'file-old',
      ),
      broadcast: false,
    );

    // Guard against a false pass. If the seed above did not land under the key
    // the screen actually reads, the query would miss the cache, go to the
    // network for unrelated reasons, and this test would go green while the
    // bug it exists to catch was fully intact.
    expect(
      cache.readQuery(_candidatesRequest()),
      isNotNull,
      reason: 'the cache must genuinely hold a stale entry for this query, '
          'otherwise the assertion below proves nothing',
    );

    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      // What the server says today, after the file was replaced.
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
      cache: cache,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(
      tester,
      () => proxyService.directStreamFileIds.isNotEmpty,
    );

    expect(
      proxyService.directStreamFileIds,
      contains('file-new'),
      reason: 'the file to play is a fact about current server state, so it '
          'has to come from the server and not from a cache entry that '
          'outlived the file it names',
    );
    expect(
      proxyService.directStreamFileIds,
      isNot(contains('file-old')),
      reason: 'file-old no longer exists; streaming it is the black screen',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('the candidates query reaches the network on every playback',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final cache = GraphQLCache(store: InMemoryStore());
    cache.writeQuery(
      _candidatesRequest(),
      data: streamingCandidatesResponse(
        duration: 5400,
        directPlay: true,
        fileId: 'file-old',
      ),
      broadcast: false,
    );

    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
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
