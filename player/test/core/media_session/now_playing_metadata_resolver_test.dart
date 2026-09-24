import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/media_session/media_session_state.dart';
import 'package:player/core/media_session/now_playing_metadata_resolver.dart';

void main() {
  group('NowPlayingMetadataResolver', () {
    late List<Map<String, dynamic>> calls;
    Map<String, dynamic>? response;
    Object? error;

    NowPlayingMetadataResolver build() => NowPlayingMetadataResolver(
          (document, variables) async {
            calls.add(variables);
            if (error != null) throw error!;
            return response;
          },
        );

    setUp(() {
      calls = [];
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
      final metadata =
          await build().resolve(mediaItemId: 'show-1', episodeId: 'ep-7');
      expect(
        metadata,
        const NowPlayingMetadata(
          title: 'The Lantern Keeper',
          subtitle: 'Harbor Lights · S2E5',
          posterUrl: 'https://img.example/harbor.jpg',
        ),
      );
      expect(calls.single, {'id': 'ep-7'});
    });

    test('a movie keeps the snapshot title and shows the year', () async {
      response = {
        'movie': {
          'year': 2031,
          'artwork': {'posterUrl': 'https://img.example/orchard.jpg'},
        },
      };
      final metadata = await build().resolve(mediaItemId: 'movie-1');
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
      final metadata = await build().resolve(episodeId: 'ep-7');
      expect(metadata, const NowPlayingMetadata(subtitle: 'Harbor Lights'));
    });

    test('a fetch failure resolves to null', () async {
      error = Exception('offline');
      expect(await build().resolve(mediaItemId: 'movie-1'), isNull);
    });

    test('no data resolves to null', () async {
      expect(await build().resolve(mediaItemId: 'movie-1'), isNull);
    });

    test('no ids resolves to null without fetching', () async {
      expect(await build().resolve(), isNull);
      expect(calls, isEmpty);
    });

    test('a fetch that could not reach the server yet retries next time',
        () async {
      error = NowPlayingFetchUnavailable();
      final resolver = build();
      final first = await resolver.resolve(mediaItemId: 'movie-1');
      expect(first, isNull);

      error = null;
      response = {
        'movie': {
          'year': 2031,
          'artwork': {'posterUrl': 'https://img.example/orchard.jpg'},
        },
      };
      final second = await resolver.resolve(mediaItemId: 'movie-1');
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
      await resolver.resolve(mediaItemId: 'movie-1');
      await resolver.resolve(mediaItemId: 'movie-1');
      expect(calls, hasLength(1));
      await resolver.resolve(mediaItemId: 'movie-2');
      expect(calls, hasLength(2));
    });
  });
}
