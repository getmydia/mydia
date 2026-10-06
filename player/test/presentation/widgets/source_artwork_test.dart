import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/artwork_decode.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/watch_status.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/widgets/media_poster.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../screens/sources/fake_media_source.dart';

void main() {
  test('the image provider carries the cache key and headers', () {
    final provider = artworkImageProvider(
      'https://fake.test/a',
      cacheKey: 'k',
      headers: const {'X-Plex-Token': 'tok'},
    ) as ArtworkNetworkImageProvider;
    expect(provider.cacheKey, 'k');
    expect(provider.headers, {'X-Plex-Token': 'tok'});
  });

  test('watch status from user state', () {
    expect(
        watchStatusFor(const UserState(watched: true), 100)!.watched, isTrue);
    expect(
        watchStatusFor(const UserState(progressSeconds: 25), 100)!.percentage,
        25);
    expect(watchStatusFor(const UserState(), 100), isNull);
  });

  test('a show with unwatched episodes carries the count', () {
    final status = watchStatusFor(const UserState(unwatchedCount: 6), null)!;
    expect(status.unwatchedEpisodeCount, 6);
    expect(status.isUnwatchedContainer, isTrue);
    expect(watchStatusFor(const UserState(unwatchedCount: 0), null), isNull);
    expect(
        watchStatusFor(const UserState(watched: true, unwatchedCount: 3), null)!
            .watched,
        isTrue);
  });

  testWidgets('SourcePoster resolves artwork through the source',
      (tester) async {
    final fake = FakeMediaSource();
    await tester.pumpWidget(ProviderScope(
      overrides: [mediaSourceProvider(fakeSourceId).overrideWithValue(fake)],
      child: MaterialApp(
        home: SizedBox(
          width: 200,
          height: 320,
          child: SourcePoster(item: fakeMovie(1, progress: 600)),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    final poster = tester.widget<MediaPoster>(find.byType(MediaPoster));
    expect(poster.posterUrl, 'https://fake.test/art/m1?w=400');
    expect(poster.posterHeaders, {'X-Plex-Token': 'tok'});
    expect(poster.posterCacheKey, '$fakeSourceId|/art/m1|400');
    expect(poster.title, 'Invented Film 1');
    expect(poster.watchStatus, isA<WatchStatus>());
    expect(poster.watchStatus!.percentage, 10);
  });
}
