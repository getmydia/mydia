import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/player/session/plex_playback_session.dart';
import 'package:player/presentation/screens/player/session/source_playback_sessions.dart';
import 'package:player/presentation/screens/sources/source_player_route.dart';

import '../../../core/sources/plex/plex_media_source_test.dart' as plex;
import 'fake_media_source.dart';

void main() {
  test('builds a Plex session for a Plex source, none for others', () {
    final source = plex.build().source;
    const item = ItemRef(
        sourceId: fakeSourceId, kind: ItemKind.movie, externalId: '101');
    expect(playbackSessionFor(source, item, '21'), isA<PlexPlaybackSession>());
    expect(playbackSessionFor(FakeMediaSource(), item, '21'), isNull);
  });

  test('reads kind, file and title from the location', () {
    final params = SourcePlayerParams.fromUri(Uri.parse(
        '/s/x/player/e2?kind=episode&fileId=p9&title=Invented%20Episode'));
    expect(params.kind, ItemKind.episode);
    expect(params.fileId, 'p9');
    expect(params.title, 'Invented Episode');
    expect(params.mediaType, 'episode');
    expect(
        SourcePlayerParams.fromUri(Uri.parse('/s/x/player/v1?kind=video'))
            .mediaType,
        'movie');
  });

  testWidgets('a source with no playback says so instead of crashing',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource())
      ],
      child: MaterialApp(
        home: SourcePlayerRoute(
          sourceId: fakeSourceId,
          itemId: 'm1',
          uri: Uri.parse('/s/x/player/m1?kind=movie&fileId=part-1'),
        ),
      ),
    ));
    expect(find.byKey(const Key('source-player-unavailable')), findsOneWidget);
  });
}
