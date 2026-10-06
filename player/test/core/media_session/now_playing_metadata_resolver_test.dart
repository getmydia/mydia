import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/media_session/media_session_state.dart';
import 'package:player/core/media_session/now_playing_metadata_resolver.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';

import '../../test_utils/mydia_test_source.dart';
import '../sources/mydia/fake_mydia_transport.dart';

const _idA = SourceId('acct-a:owner:inst-a');
const _idB = SourceId('acct-b:owner:inst-b');

Map<String, dynamic> _movie(String poster) => {
      'movie': {
        'year': 2031,
        'artwork': {'posterUrl': poster},
      },
    };

void main() {
  group('NowPlayingMetadataResolver', () {
    late List<Map<String, dynamic>> calls;
    late List<SourceId> asked;
    Map<String, dynamic>? response;
    Exception? error;

    NowPlayingMetadataResolver build() => NowPlayingMetadataResolver(
          (id, document, variables) async {
            asked.add(id);
            calls.add(variables);
            if (error != null) throw error!;
            return response;
          },
        );

    setUp(() {
      calls = [];
      asked = [];
      response = null;
      error = null;
    });

    test('an episode gets its own title, show and code, and the show poster',
        () async {
      response = {
        'episode': {
          'seasonNumber': 2,
          'episodeNumber': 5,
          'title': 'The Lantern Keeper',
          'show': {
            'title': 'Harbor Lights',
            'artwork': {'posterUrl': 'https://img.example/harbor.jpg'},
          },
        },
      };
      final metadata = await build()
          .resolve(sourceId: _idA, mediaItemId: 'show-1', episodeId: 'ep-7');
      expect(
        metadata,
        const NowPlayingMetadata(
          title: 'The Lantern Keeper',
          subtitle: 'Harbor Lights · S2E5',
          posterUrl: 'https://img.example/harbor.jpg',
        ),
      );
      expect(calls.single, {'id': 'ep-7'});
      expect(asked.single, _idA);
    });

    test('a movie keeps the snapshot title and shows the year', () async {
      response = _movie('https://img.example/orchard.jpg');
      final metadata =
          await build().resolve(sourceId: _idA, mediaItemId: 'movie-1');
      expect(
        metadata,
        const NowPlayingMetadata(
          subtitle: '2031',
          posterUrl: 'https://img.example/orchard.jpg',
        ),
      );
      expect(calls.single, {'id': 'movie-1'});
    });

    test('missing episode parts are omitted from the subtitle', () async {
      response = {
        'episode': {
          'seasonNumber': null,
          'episodeNumber': null,
          'title': null,
          'show': {'title': 'Harbor Lights', 'artwork': null},
        },
      };
      final metadata = await build().resolve(sourceId: _idA, episodeId: 'ep-7');
      expect(metadata, const NowPlayingMetadata(subtitle: 'Harbor Lights'));
    });

    test('a fetch failure resolves to null', () async {
      error = Exception('offline');
      expect(await build().resolve(sourceId: _idA, mediaItemId: 'movie-1'),
          isNull);
    });

    test('no data resolves to null', () async {
      expect(await build().resolve(sourceId: _idA, mediaItemId: 'movie-1'),
          isNull);
    });

    test('no ids resolves to null without fetching', () async {
      expect(await build().resolve(sourceId: _idA), isNull);
      expect(calls, isEmpty);
    });

    test('a fetch that could not reach the server yet retries next time',
        () async {
      error = NowPlayingFetchUnavailable();
      final resolver = build();
      final first =
          await resolver.resolve(sourceId: _idA, mediaItemId: 'movie-1');
      expect(first, isNull);

      error = null;
      response = _movie('https://img.example/orchard.jpg');
      final second =
          await resolver.resolve(sourceId: _idA, mediaItemId: 'movie-1');
      expect(
        second,
        const NowPlayingMetadata(
          subtitle: '2031',
          posterUrl: 'https://img.example/orchard.jpg',
        ),
      );
      expect(calls, hasLength(2));
    });

    test('memoises per item, including failures', () async {
      error = Exception('offline');
      final resolver = build();
      await resolver.resolve(sourceId: _idA, mediaItemId: 'movie-1');
      await resolver.resolve(sourceId: _idA, mediaItemId: 'movie-1');
      expect(calls, hasLength(1));
      await resolver.resolve(sourceId: _idA, mediaItemId: 'movie-2');
      expect(calls, hasLength(2));
    });

    test('the same ids on two instances are two items', () async {
      response = _movie('https://img.example/orchard.jpg');
      final resolver = build();
      await resolver.resolve(sourceId: _idA, mediaItemId: 'movie-1');
      await resolver.resolve(sourceId: _idB, mediaItemId: 'movie-1');
      expect(asked, [_idA, _idB]);
    });
  });

  group('nowPlayingMetadataResolverProvider', () {
    test('resolves through the instance that is playing', () async {
      final a = FakeMydiaTransport()
        ..handlers['NowPlayingMovie'] =
            (_) => _movie('https://img.example/from-a.jpg');
      final b = FakeMydiaTransport()
        ..handlers['NowPlayingMovie'] =
            (_) => _movie('https://img.example/from-b.jpg');
      final container = ProviderContainer(overrides: [
        mediaSourceProvider(_idA)
            .overrideWithValue(testMydiaSourceOver(a, accountId: 'acct-a')),
        mediaSourceProvider(_idB)
            .overrideWithValue(testMydiaSourceOver(b, accountId: 'acct-b')),
      ]);
      addTearDown(container.dispose);

      final metadata = await container
          .read(nowPlayingMetadataResolverProvider)
          .resolve(sourceId: _idB, mediaItemId: 'movie-1');

      expect(metadata?.posterUrl, 'https://img.example/from-b.jpg');
      expect(b.calls.single.vars, {'id': 'movie-1'});
      expect(a.calls, isEmpty);
    });

    test(
        'a source that is not there is unavailable, so the next try asks again',
        () async {
      final server = FakeMydiaTransport();
      server.handlers['NowPlayingMovie'] = (_) => {
            'movie': {'year': 2031, 'artwork': null},
          };
      var present = false;
      final container = ProviderContainer(overrides: [
        mediaSourceProvider(_idA).overrideWith(
            (ref) => present ? testMydiaSourceOver(server) : null),
      ]);
      addTearDown(container.dispose);
      final resolver = container.read(nowPlayingMetadataResolverProvider);

      expect(await resolver.resolve(sourceId: _idA, mediaItemId: 'movie-1'),
          isNull);

      present = true;
      container.invalidate(mediaSourceProvider(_idA));
      expect(
          (await resolver.resolve(sourceId: _idA, mediaItemId: 'movie-1'))
              ?.subtitle,
          '2031');
    });

    test('a refused query resolves to null', () async {
      final server = FakeMydiaTransport();
      server.unreachable = true;
      final container = ProviderContainer(overrides: [
        mediaSourceProvider(_idA)
            .overrideWithValue(testMydiaSourceOver(server)),
      ]);
      addTearDown(container.dispose);

      expect(
          await container
              .read(nowPlayingMetadataResolverProvider)
              .resolve(sourceId: _idA, mediaItemId: 'movie-1'),
          isNull);
    });
  });
}
