import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_content.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/player/session/jellyfin_playback_session.dart';
import 'package:player/presentation/screens/player/session/plex_playback_session.dart';
import 'package:player/presentation/screens/player/session/source_cast_binding_impl.dart';
import 'package:player/presentation/screens/player/session/stash_playback_session.dart';

import '../../../../core/sources/jellyfin/fake_jellyfin_server.dart';
import '../../../../core/sources/jellyfin/jellyfin_media_source_test.dart' as jf
    show build, jellyfinSid;
import '../../../../core/sources/plex/fake_plex_server.dart';
import '../../../../core/sources/plex/plex_media_source_test.dart' as px
    show build;
import '../../../../core/sources/stash/fake_stash_server.dart';
import '../../../../core/sources/stash/stash_media_source_test.dart' as st
    show build;

void main() {
  test('a source that is no longer in the app cannot be cast from', () async {
    final container = ProviderContainer(overrides: [
      sourcesProvider.overrideWithValue(const []),
    ]);
    addTearDown(container.dispose);
    final refProvider = Provider<Ref>((ref) => ref);

    await expectLater(
      bindSourceCast(
        container.read(refProvider),
        const SourceCastContent(
          item: ItemRef(
              sourceId: SourceId('px1:owner:gone'),
              kind: ItemKind.movie,
              externalId: '1'),
          versionId: '1',
        ),
      ),
      throwsA(isA<CastBackendException>()
          .having((e) => e.kind, 'kind', CastFailureKind.unknown)),
    );
  });

  group('Plex', () {
    const movie = ItemRef(
        sourceId: SourceId('acc1:owner:abc123'),
        kind: ItemKind.movie,
        externalId: '101');

    ({SessionSourceCastBinding binding, FakePlexServer server}) open() {
      final b = px.build();
      return (
        binding: SessionSourceCastBinding(
            PlexPlaybackSession(source: b.source, item: movie, fileId: '21')),
        server: b.server,
      );
    }

    test('Chromecast gets an HLS route with the token and a session id',
        () async {
      final route = await open().binding.resolve(
            protocol: CastProtocolKind.chromecast,
            startPosition: Duration.zero,
            subtitleTrackId: null,
            forceTranscode: false,
          );
      expect(route.mediaKind, CastMediaKind.hls);
      expect(route.kind, CastRouteKind.directServer);
      expect(Uri.parse(route.mediaUrl).queryParameters['X-Plex-Token'],
          FakePlexServer.token);
      expect(route.hlsSessionId, isNotNull);
    });

    test('offers every subtitle as burned in', () async {
      final route = await open().binding.resolve(
            protocol: CastProtocolKind.chromecast,
            startPosition: Duration.zero,
            subtitleTrackId: null,
            forceTranscode: false,
          );
      // 33 is a text track, 34 an image (PGS) one; both are burned in.
      expect(route.subtitles.map((t) => t.trackId), ['33', '34']);
      expect(route.subtitles.every((t) => t.burnedIn), isTrue);
      expect(route.subtitles.every((t) => t.url.isEmpty), isTrue);
    });

    test('choosing a burned track transcodes', () async {
      final route = await open().binding.resolve(
            protocol: CastProtocolKind.chromecast,
            startPosition: Duration.zero,
            subtitleTrackId: '33',
            forceTranscode: false,
          );
      expect(route.transcoded, isTrue);
      expect(Uri.parse(route.mediaUrl).queryParameters['subtitles'], 'burn');
    });

    test('DLNA gets the direct file and no subtitles', () async {
      final route = await open().binding.resolve(
            protocol: CastProtocolKind.dlna,
            startPosition: Duration.zero,
            subtitleTrackId: null,
            forceTranscode: false,
          );
      expect(route.mediaKind, CastMediaKind.progressive);
      expect(Uri.parse(route.mediaUrl).path,
          '/library/parts/21/1700000000/file.mkv');
      expect(route.subtitles, isEmpty);
    });

    test('ending the server session stops the Plex transcode', () async {
      final o = open();
      final route = await o.binding.resolve(
        protocol: CastProtocolKind.chromecast,
        startPosition: Duration.zero,
        subtitleTrackId: null,
        forceTranscode: true,
      );
      await o.binding.endServerSession(route.hlsSessionId!);
      expect(
          o.server.requests.last.url.path, '/video/:/transcode/universal/stop');
    });

    test('progress reaches the Plex timeline', () async {
      final o = open();
      await o.binding.openProgress().report(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 90),
          paused: false);
      expect(o.server.requests.last.url.path, '/:/timeline');
    });
  });

  group('Jellyfin', () {
    const movie = ItemRef(
        sourceId: jf.jellyfinSid, kind: ItemKind.movie, externalId: 'm2');

    test('text subtitles become VTT sidecars with api_key', () async {
      final b = jf.build();
      final binding = SessionSourceCastBinding(
          JellyfinPlaybackSession(source: b.source, item: movie, fileId: 'm2'));
      final route = await binding.resolve(
        protocol: CastProtocolKind.chromecast,
        startPosition: Duration.zero,
        subtitleTrackId: null,
        forceTranscode: false,
      );
      expect(route.subtitles, hasLength(2));
      for (final track in route.subtitles) {
        final url = Uri.parse(track.url);
        expect(url.path, endsWith('/Stream.vtt'));
        expect(url.queryParameters['api_key'], FakeJellyfinServer.token);
        expect(track.burnedIn, isFalse);
      }
    });
  });

  group('Stash', () {
    const scene = ItemRef(
        sourceId: SourceId('st1:owner:main'),
        kind: ItemKind.video,
        externalId: '2');

    test('a rejected key surfaces as notAuthorized', () async {
      final b = st.build();
      b.server.status = 401;
      final binding = SessionSourceCastBinding(
          StashPlaybackSession(source: b.source, item: scene, fileId: '92'));

      await expectLater(
        binding.resolve(
          protocol: CastProtocolKind.chromecast,
          startPosition: Duration.zero,
          subtitleTrackId: null,
          forceTranscode: false,
        ),
        throwsA(isA<CastBackendException>()
            .having((e) => e.kind, 'kind', CastFailureKind.notAuthorized)),
      );
    });

    test('captions become sidecars with apikey', () async {
      final b = st.build();
      final binding = SessionSourceCastBinding(
          StashPlaybackSession(source: b.source, item: scene, fileId: '92'));
      final route = await binding.resolve(
        protocol: CastProtocolKind.chromecast,
        startPosition: Duration.zero,
        subtitleTrackId: null,
        forceTranscode: false,
      );
      expect(Uri.parse(route.mediaUrl).queryParameters['apikey'],
          FakeStashServer.apiKey);
      expect(route.subtitles, hasLength(1));
      for (final track in route.subtitles) {
        expect(Uri.parse(track.url).path, '/scene/2/caption');
        expect(Uri.parse(track.url).queryParameters['apikey'],
            FakeStashServer.apiKey);
      }
    });
  });
}
