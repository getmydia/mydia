import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/sources/lock/device_auth.dart';
import 'package:player/core/sources/lock/source_lock_controller.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/screens/player/session/plex_playback_session.dart';
import 'package:player/presentation/screens/player/session/source_playback_sessions.dart';
import 'package:player/presentation/screens/sources/source_player_route.dart';

import '../../../core/sources/plex/plex_media_source_test.dart' as plex;
import 'fake_media_source.dart';

class _AllowAuth implements DeviceAuth {
  @override
  Future<bool> available() async => true;
  @override
  Future<DeviceAuthResult> authenticate() async => DeviceAuthResult.success;
}

void main() {
  test('builds a Plex session for a Plex source, none for others', () {
    final source = plex.build().source;
    const item = ItemRef(
        sourceId: fakeSourceId, kind: ItemKind.movie, externalId: '101');
    final proxy = LocalProxyService.forTesting;
    expect(playbackSessionFor(source, item, '21', proxy: proxy),
        isA<PlexPlaybackSession>());
    expect(playbackSessionFor(FakeMediaSource(), item, '21', proxy: proxy),
        isNull);
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

  test('reads the show, season and resume point from the location', () {
    final params = SourcePlayerParams.fromUri(Uri.parse(
        '/s/x/player/e2?kind=episode&fileId=p9&showId=s1&seasonNumber=1'
        '&resume=300'));
    expect(params.showId, 's1');
    expect(params.seasonNumber, 1);
    expect(params.resumeSeconds, 300);
    final bare =
        SourcePlayerParams.fromUri(Uri.parse('/s/x/player/e2?fileId=p9'));
    expect(bare.showId, isNull);
    expect(bare.seasonNumber, isNull);
    expect(bare.resumeSeconds, isNull);
  });

  test('reads the tracks and autoplay a remote load content carries', () {
    final params = SourcePlayerParams.fromUri(Uri.parse(
        '/s/x/player/m1?kind=movie&fileId=p9&audioTrack=a1&subtitleTrack=s2'
        '&autoplay=false'));
    expect(params.audioTrack, 'a1');
    expect(params.subtitleTrack, 's2');
    expect(params.autoplay, isFalse);
    final bare = SourcePlayerParams.fromUri(Uri.parse('/s/x/player/m1'));
    expect(bare.audioTrack, isNull);
    expect(bare.subtitleTrack, isNull);
    expect(bare.autoplay, isTrue);
  });

  testWidgets('hands the tracks and autoplay to the player screen',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(plex.build().source)
      ],
      child: MaterialApp(
        home: SourcePlayerRoute(
          sourceId: fakeSourceId,
          itemId: 'm1',
          uri: Uri.parse('/s/x/player/m1?kind=movie&fileId=p9&audioTrack=a1'
              '&subtitleTrack=s2&autoplay=false'),
        ),
      ),
    ));
    final screen = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    expect(screen.audioTrack, 'a1');
    expect(screen.subtitleTrack, 's2');
    expect(screen.autoplay, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hands the show, season and resume point to the player screen',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(plex.build().source)
      ],
      child: MaterialApp(
        home: SourcePlayerRoute(
          sourceId: fakeSourceId,
          itemId: 'e2',
          uri: Uri.parse(
              '/s/x/player/e2?kind=episode&fileId=p9&showId=s1&seasonNumber=1'
              '&resume=300'),
        ),
      ),
    ));
    final screen = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    expect(screen.showId, 's1');
    expect(screen.seasonNumber, 1);
    expect(screen.resumeSeconds, 300);
    expect(screen.mediaType, 'episode');
    await tester.pumpWidget(const SizedBox());
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

  testWidgets('an empty file id is unavailable rather than a blank stream',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(plex.build().source)
      ],
      child: MaterialApp(
        home: SourcePlayerRoute(
          sourceId: fakeSourceId,
          itemId: 'm1',
          uri: Uri.parse('/s/x/player/m1?kind=movie'),
        ),
      ),
    ));
    expect(find.byKey(const Key('source-player-unavailable')), findsOneWidget);
  });

  testWidgets('navigating to another item in place builds a fresh route state',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/s/x/player/a?fileId=f',
      routes: [
        GoRoute(
          path: '/s/:sourceId/player/:itemId',
          builder: sourcePlayerRouteBuilder,
        ),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(const SourceId('x'))
            .overrideWithValue(FakeMediaSource())
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    final first = tester.state(find.byType(SourcePlayerRoute));

    router.go('/s/x/player/b?fileId=f');
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(SourcePlayerRoute)), isNot(same(first)));
  });

  Future<ProviderContainer> pumpRoute(
    WidgetTester tester,
    Map<SourceId, SourceLock> locks,
  ) async {
    final container = ProviderContainer(overrides: [
      deviceAuthProvider.overrideWithValue(_AllowAuth()),
      mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
      sourceLocksProvider.overrideWithValue(locks),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: SourcePlayerRoute(
          sourceId: fakeSourceId,
          itemId: 'm1',
          uri: Uri.parse('/s/x/player/m1?kind=movie&fileId=part-1'),
        ),
      ),
    ));
    return container;
  }

  testWidgets('playing a locked source holds the lock until the route goes',
      (tester) async {
    final container =
        await pumpRoute(tester, {fakeSourceId: SourceLock.locked});
    expect(container.read(sourceLockProvider.notifier).holding, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(container.read(sourceLockProvider.notifier).holding, isFalse);
  });

  testWidgets('a deferred relock fires after the frame, not in dispose',
      (tester) async {
    final container =
        await pumpRoute(tester, {fakeSourceId: SourceLock.locked});
    final lock = container.read(sourceLockProvider.notifier);
    await lock.unlockWithDevice();
    expect(container.read(sourceLockProvider), isTrue);
    // Expire the grace while holding.
    lock.onLifecycle(AppLifecycleState.paused);
    await tester.pump(kRelockGrace + const Duration(seconds: 1));
    expect(container.read(sourceLockProvider), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(container.read(sourceLockProvider), isFalse);
  });

  testWidgets('playing an unlocked source holds nothing', (tester) async {
    final container = await pumpRoute(tester, {});
    expect(container.read(sourceLockProvider.notifier).holding, isFalse);
  });
}
