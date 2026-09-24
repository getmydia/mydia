import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/media_session/media_session_bridge.dart';
import 'package:player/core/media_session/media_session_state.dart';
import 'package:player/core/media_session/now_playing_metadata_resolver.dart';
import 'package:player/core/media_session/system_media_session.dart';
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/core/remote/remote_target_controller.dart';
import 'package:player/native/lib.dart';

import 'fakes.dart';

void main() {
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  late RemoteTargetController controller;
  late FakeMediaSession session;
  late List<String> artworkRequests;
  late int raises;
  String? artworkResult;

  NowPlayingMetadataResolver resolver({String? posterUrl}) =>
      NowPlayingMetadataResolver((document, variables) async => {
            'movie': {
              'year': 2031,
              'artwork': {'posterUrl': posterUrl},
            },
          });

  MediaSessionBridge build({
    NowPlayingMetadataResolver? metadata,
    Future<SystemMediaSession> Function()? createSession,
  }) =>
      MediaSessionBridge(
        controller: controller,
        createSession: createSession ?? () async => session,
        resolver: metadata ?? resolver(),
        loadArtwork: (url) async {
          artworkRequests.add(url);
          return artworkResult;
        },
        raiseWindow: () async => raises++,
      );

  setUp(() {
    controller = RemoteTargetController();
    session = FakeMediaSession();
    artworkRequests = [];
    raises = 0;
    artworkResult = '/cache/orchard.jpg';
  });

  tearDown(() => controller.dispose());

  test('starts stopped when nothing is attached', () async {
    final bridge = build();
    await bridge.start();
    await settle();
    expect(session.updates.last, MediaSessionState.stopped);
    await bridge.dispose();
  });

  test('pushes the attached player with metadata and artwork', () async {
    final bridge =
        build(metadata: resolver(posterUrl: 'https://img.example/orchard.jpg'));
    await bridge.start();
    controller.attachPlayer(FakeBinding(buildSnapshot()));
    await settle();

    final state = session.updates.last;
    expect(state.status, MediaSessionStatus.playing);
    expect(state.title, 'The Glass Orchard');
    expect(state.subtitle, '2031');
    expect(state.artworkPath, '/cache/orchard.jpg');
    await bridge.dispose();
  });

  test('loads each poster once', () async {
    final bridge =
        build(metadata: resolver(posterUrl: 'https://img.example/orchard.jpg'));
    await bridge.start();
    final binding = FakeBinding(buildSnapshot());
    controller.attachPlayer(binding);
    await settle();
    binding.current = buildSnapshot(state: FlutterPlaybackState.paused);
    controller.notifyChanged();
    await settle();

    expect(session.updates.last.status, MediaSessionStatus.paused);
    expect(artworkRequests, ['https://img.example/orchard.jpg']);
    await bridge.dispose();
  });

  test('an artwork failure still pushes metadata', () async {
    artworkResult = null;
    final bridge =
        build(metadata: resolver(posterUrl: 'https://img.example/orchard.jpg'));
    await bridge.start();
    controller.attachPlayer(FakeBinding(buildSnapshot()));
    await settle();
    expect(session.updates.last.artworkPath, isNull);
    expect(session.updates.last.subtitle, '2031');
    await bridge.dispose();
  });

  test('retries artwork after a failed load', () async {
    artworkResult = null;
    final bridge =
        build(metadata: resolver(posterUrl: 'https://img.example/orchard.jpg'));
    await bridge.start();
    controller.attachPlayer(FakeBinding(buildSnapshot()));
    await settle();
    expect(session.updates.last.artworkPath, isNull);

    artworkResult = '/cache/orchard.jpg';
    controller.notifyChanged();
    await settle();

    expect(artworkRequests, [
      'https://img.example/orchard.jpg',
      'https://img.example/orchard.jpg',
    ]);
    expect(session.updates.last.artworkPath, '/cache/orchard.jpg');
    await bridge.dispose();
  });

  test('detaching returns to stopped', () async {
    final bridge = build();
    await bridge.start();
    final binding = FakeBinding(buildSnapshot());
    controller.attachPlayer(binding);
    await settle();
    controller.detachPlayer(binding);
    await settle();
    expect(session.updates.last, MediaSessionState.stopped);
    await bridge.dispose();
  });

  test('OS commands reach the attached player', () async {
    final bridge = build();
    await bridge.start();
    final binding = FakeBinding(buildSnapshot());
    controller.attachPlayer(binding);
    await settle();

    session.commandsIn.add(const TransportIntent(TransportAction.pause));
    session.commandsIn.add(const EpisodeStepIntent(EpisodeStep.next));
    await settle();
    expect(binding.calls, ['pause', 'episode:next']);
    await bridge.dispose();
  });

  test('raise requests raise the window', () async {
    final bridge = build();
    await bridge.start();
    session.raiseIn.add(null);
    await settle();
    expect(raises, 1);
    await bridge.dispose();
  });

  test('a failing session update is swallowed', () async {
    session.throwOnUpdate = true;
    final bridge = build();
    await bridge.start();
    controller.attachPlayer(FakeBinding(buildSnapshot()));
    await settle(); // must not throw
    await bridge.dispose();
  });

  test('a session that fails to start falls back to a no-op', () async {
    final bridge = build(createSession: () async => throw StateError('no bus'));
    await bridge.start(); // must not throw
    controller.attachPlayer(FakeBinding(buildSnapshot()));
    await settle();
    await bridge.dispose();
  });

  test('a no-op session skips metadata and artwork lookups entirely', () async {
    final fetchCalls = <String>[];
    final noopResolver =
        NowPlayingMetadataResolver((document, variables) async {
      fetchCalls.add(document);
      return null;
    });
    final bridge = build(
      createSession: () async => NoopMediaSession(),
      metadata: noopResolver,
    );
    await bridge.start();
    controller.attachPlayer(FakeBinding(buildSnapshot()));
    await settle();
    expect(fetchCalls, isEmpty);
    expect(artworkRequests, isEmpty);
    await bridge.dispose();
  });

  test('dispose disposes the session and stops listening', () async {
    final bridge = build();
    await bridge.start();
    await settle();
    await bridge.dispose();
    expect(session.disposed, isTrue);
    final count = session.updates.length;
    controller.notifyChanged();
    await settle();
    expect(session.updates.length, count);
  });
}
