// Regression coverage for `_loadSubtitleOffsets` and a warm cache.
//
// `GraphQLClient.query` defaults to `FetchPolicy.cacheFirst`, and these
// clients sit on a persistent `HiveStore` in the real app. Without an
// explicit `FetchPolicy.networkOnly` on this query, a viewer who already
// played this file would have `_subtitleOffsets` populated from whatever
// offset was cached the last time this file loaded -- not what the server
// actually has on file now. `_saveSubtitleDelay` then sends that stale
// baseline plus the current nudge, silently overwriting a newer server
// offset with an older one.
//
// Mirrors `player_screen_stale_candidates_test.dart`'s second test: asserting
// on the transport, not just the outcome, is what catches a regression back
// to the cache-first default. A one-shot `client.query()` with a warm cache
// entry never reaches the link at all under `cacheFirst`, so a test that only
// checked the resolved offset value could pass for the wrong reason (the
// cached value happening to match).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/graphql/queries/subtitle_track_settings.graphql.dart';

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

/// The request `_loadSubtitleOffsets` issues for [mediaFileId].
Request _subtitleTrackSettingsRequest(String mediaFileId) => Request(
      operation: const Operation(
        document: documentNodeQuerySubtitleTrackSettings,
      ),
      variables: Variables$Query$SubtitleTrackSettings(
        mediaFileId: mediaFileId,
      ).toJson(),
    );

void main() {
  testWidgets(
      'the subtitle offsets query reaches the network even with a warm '
      'cache entry', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // Stands in for an install that already played file-1 in an earlier
    // session: the cache holds a stale answer for exactly the query and
    // variables `_loadSubtitleOffsets` issues now.
    final cache = GraphQLCache(store: InMemoryStore());
    cache.writeQuery(
      _subtitleTrackSettingsRequest('file-1'),
      data: subtitleTrackSettingsResponse(settings: [
        {
          '__typename': 'SubtitleTrackSetting',
          'trackRef': '3',
          'offsetMs': 999,
        },
      ]),
      broadcast: false,
    );

    // Guard against a false pass: if the seed above missed the key the
    // screen actually reads, the query would miss the cache and go to the
    // network for unrelated reasons, and the assertion below would prove
    // nothing.
    expect(
      cache.readQuery(_subtitleTrackSettingsRequest('file-1')),
      isNotNull,
      reason: 'the cache must genuinely hold a stale entry for this query, '
          'otherwise the assertion below proves nothing',
    );

    final link = StubLink.responses([
      movieDetailResponse(files: [mediaFileWithSubtitle()]),
      movieSegmentsResponse(),
      // What the server says today for this file's offsets -- different
      // from the stale cached entry above, so a regression to cacheFirst
      // would both skip this response and hand back the wrong offset.
      subtitleTrackSettingsResponse(settings: [
        {
          '__typename': 'SubtitleTrackSetting',
          'trackRef': '3',
          'offsetMs': 111
        },
      ]),
      streamingCandidatesResponse(duration: 5400, directPlay: true),
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

    // Asserting on the transport rather than only on the outcome: a
    // cacheFirst policy never reaches the link at all for a warm entry, so
    // this is the only way to actually distinguish "used the cache" from
    // "used the network and happened to agree with it".
    expect(
      link.requests
          .where((r) =>
              r.operation.document == documentNodeQuerySubtitleTrackSettings)
          .length,
      1,
      reason: 'a warm cache entry must not stand in for asking the server '
          'for the current offsets',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
