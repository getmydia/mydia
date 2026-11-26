// A movie-typed item (a Stash scene) whose session knows the previous and
// next scene of the listing it was opened from gets the episode transport
// buttons, and they route to the session's sequence location.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/sources/source.dart' show SourceId;
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/playback_sequence.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';

import '../../../test_utils/probed_tracks.dart';
import '../../../test_utils/scripted_mydia_transport.dart';
import '../../../test_utils/toast_harness.dart';
import 'player_screen_test_harness.dart';
import 'session/fake_playback_session.dart';

class _PlatformPlayer extends PlatformPlayer {
  _PlatformPlayer() : super(configuration: const PlayerConfiguration());

  final _handle = Completer<int>();
  Media? opened;

  @override
  Future<int> get handle => _handle.future;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened = playable as Media;
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: Duration.zero,
      tracks: probedTracks(),
    );
    durationController.add(state.duration);
    positionController.add(state.position);
    tracksController.add(state.tracks);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  void seekTo(Duration position) {
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  void complete() {
    state = state.copyWith(completed: true, position: state.duration);
    completedController.add(true);
  }
}

SequenceNeighbour _scene(String id, int position) => SequenceNeighbour(
  item: ItemSummary(
    ref: ItemRef(
      sourceId: const SourceId('fake'),
      kind: ItemKind.movie,
      externalId: id,
    ),
    title: 'Invented Scene $id',
    defaultVersionId: 'file-$id',
  ),
  position: position,
);

class _SceneSession extends FakePlaybackSession {
  _SceneSession(this.neighbours);

  final SequenceNeighbours? neighbours;
  int asked = 0;

  @override
  Future<SequenceNeighbours?> sequenceNeighbours() async {
    asked++;
    return neighbours;
  }

  @override
  String sequenceLocation(SequenceNeighbour neighbour) =>
      '/fake/scene/${neighbour.item.ref.externalId}';
}

ScriptedMydiaTransport _server() => ScriptedMydiaTransport(
  (request, _) => <String, dynamic>{
    '__typename': 'RootMutationType',
    'updateMovieProgress': null,
  },
);

Future<_PlatformPlayer> _pumpScene(
  WidgetTester tester,
  _SceneSession session,
) async {
  final container = buildPlayerScreenContainer(
    connectionState: HarnessLink.direct(),
    server: _server(),
    castManager: CapturingCastSessionManager(),
    proxyService: TrackingLocalProxyService(),
  );
  addTearDown(container.dispose);
  final fake = _PlatformPlayer();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => PlayerScreen(
          mediaId: 'sc-1',
          mediaType: 'movie',
          fileId: 'file-sc-1',
          title: 'Invented Scene sc-1',
          session: session,
          createPlayer: () => Player(platformPlayer: fake),
        ),
      ),
      GoRoute(
        path: '/fake/scene/:id',
        builder: (_, state) => Text('landed ${state.pathParameters['id']}'),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: toastLayerBuilder,
        routerConfig: router,
      ),
    ),
  );
  await pumpUntil(tester, () => fake.opened != null);
  await pumpUntil(tester, () => session.progress.starts.isNotEmpty);
  return fake;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  testWidgets('a movie-typed scene with neighbours shows previous and next, '
      'and next routes to the next scene', (tester) async {
    final session = _SceneSession(
      SequenceNeighbours(previous: _scene('sc-0', 0), next: _scene('sc-2', 2)),
    );
    await _pumpScene(tester, session);
    await pumpUntil(
      tester,
      () => find.byKey(TransportSurface.nextEpisodeKey).evaluate().isNotEmpty,
    );
    expect(find.byKey(TransportSurface.previousEpisodeKey), findsOneWidget);
    expect(find.byKey(TransportSurface.nextEpisodeKey), findsOneWidget);

    await tester.tap(find.byKey(TransportSurface.nextEpisodeKey));
    await pumpUntil(
      tester,
      () => find.text('landed sc-2').evaluate().isNotEmpty,
    );
    expect(find.text('landed sc-2'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a scene stays put through the Up Next window and advances '
      'only when it ends', (tester) async {
    final session = _SceneSession(SequenceNeighbours(next: _scene('sc-2', 2)));
    final fake = await _pumpScene(tester, session);
    await pumpUntil(
      tester,
      () => find.byKey(TransportSurface.nextEpisodeKey).evaluate().isNotEmpty,
    );
    await fake.play();

    // 90s scene: a 10s window. Well past what the old 10s timer allowed.
    fake.seekTo(const Duration(seconds: 85));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('landed sc-2'), findsNothing);

    fake.complete();
    await pumpUntil(
      tester,
      () => find.text('landed sc-2').evaluate().isNotEmpty,
    );
    expect(find.text('landed sc-2'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('no neighbours means no previous or next buttons', (
    tester,
  ) async {
    final session = _SceneSession(null);
    await _pumpScene(tester, session);
    await pumpUntil(tester, () => session.asked > 0);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(TransportSurface.previousEpisodeKey), findsNothing);
    expect(find.byKey(TransportSurface.nextEpisodeKey), findsNothing);
    await _unmount(tester);
  });
}
