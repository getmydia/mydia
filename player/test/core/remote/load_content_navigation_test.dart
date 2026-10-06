import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/load_content_navigation.dart';
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';

const _a = SourceId('mydia-a');
const _b = SourceId('mydia-b');

LoadContentIntent _intent({
  String mediaItemId = 'm1',
  String? episodeId,
  Duration startAt = Duration.zero,
  String? audioTrack,
  String? subtitleTrack,
  bool autoplay = true,
  SourceId? via = _b,
}) =>
    LoadContentIntent(
      mediaItemId: mediaItemId,
      episodeId: episodeId,
      startAt: startAt,
      audioTrack: audioTrack,
      subtitleTrack: subtitleTrack,
      autoplay: autoplay,
      via: via,
    );

ItemDetail _detail(
  ItemRef ref, {
  String title = 'Copper Weather',
  String? defaultVersionId,
  List<MediaVersion> versions = const [MediaVersion(id: 'file-1')],
  ItemRef? show,
  int? season,
}) =>
    ItemDetail(
      summary: ItemSummary(
        ref: ref,
        title: title,
        defaultVersionId: defaultVersionId,
        parentIndex: season,
      ),
      versions: versions,
      show: show,
    );

void main() {
  group('resolveLoadContentRoute', () {
    test('an episode resolves on the sending instance', () async {
      ItemRef? asked;
      final route = await resolveLoadContentRoute(
        _intent(episodeId: '55'),
        fetch: (ref) async {
          asked = ref;
          return _detail(
            ref,
            show: ItemRef(
                sourceId: ref.sourceId,
                kind: ItemKind.show,
                externalId: 'sh-1'),
            season: 2,
          );
        },
      );

      expect(
          asked,
          const ItemRef(
              sourceId: _b, kind: ItemKind.episode, externalId: '55'));
      expect(route, startsWith('/s/mydia-b/player/55?'));
      expect(route, contains('kind=episode'));
      expect(route, contains('fileId=file-1'));
      expect(route, contains('showId=sh-1'));
      expect(route, contains('seasonNumber=2'));
    });

    test('a movie resolves on its media item id', () async {
      ItemRef? asked;
      final route = await resolveLoadContentRoute(
        _intent(mediaItemId: 'm9', via: _a),
        fetch: (ref) async {
          asked = ref;
          return _detail(ref);
        },
      );

      expect(asked,
          const ItemRef(sourceId: _a, kind: ItemKind.movie, externalId: 'm9'));
      expect(route, startsWith('/s/mydia-a/player/m9?'));
      expect(route, contains('kind=movie'));
      expect(route, contains('title=Copper+Weather'));
      expect(route, isNot(contains('showId')));
    });

    test('the default version wins over the first one', () async {
      final route = await resolveLoadContentRoute(
        _intent(),
        fetch: (ref) async => _detail(
          ref,
          defaultVersionId: 'file-2',
          versions: const [
            MediaVersion(id: 'file-1'),
            MediaVersion(id: 'file-2')
          ],
        ),
      );

      expect(route, contains('fileId=file-2'));
    });

    test('resume, tracks and autoplay ride along', () async {
      final route = await resolveLoadContentRoute(
        _intent(
          startAt: const Duration(seconds: 754),
          audioTrack: 'audio-eng',
          subtitleTrack: 'sub-fre',
          autoplay: false,
        ),
        fetch: (ref) async => _detail(ref),
      );

      expect(route, contains('resume=754'));
      expect(route, contains('audioTrack=audio-eng'));
      expect(route, contains('subtitleTrack=sub-fre'));
      expect(route, contains('autoplay=false'));
    });

    test('absent tracks are omitted and autoplay stays implicit', () async {
      final route = await resolveLoadContentRoute(
        _intent(),
        fetch: (ref) async => _detail(ref),
      );

      expect(route, isNot(contains('audioTrack')));
      expect(route, isNot(contains('subtitleTrack')));
      expect(route, isNot(contains('autoplay')));
    });

    test('a failed fetch resolves to null', () async {
      final route = await resolveLoadContentRoute(
        _intent(),
        fetch: (ref) async => throw Exception('server unreachable'),
      );

      expect(route, isNull);
    });

    test('an item with no version resolves to null', () async {
      final route = await resolveLoadContentRoute(
        _intent(),
        fetch: (ref) async => _detail(ref, versions: const []),
      );

      expect(route, isNull);
    });

    test('an intent with no sending instance resolves to null', () async {
      final route = await resolveLoadContentRoute(
        _intent(via: null),
        fetch: (ref) async => fail('must not fetch'),
      );

      expect(route, isNull);
    });
  });

  group('pushLoadContentDestination', () {
    test('pushes the player route when it resolves', () async {
      String? pushed;
      await pushLoadContentDestination(
        _intent(),
        fetch: (ref) async => _detail(ref),
        push: (path) => pushed = path,
      );

      expect(pushed, startsWith('/s/mydia-b/player/m1?'));
    });

    test('falls back to the detail screen on the same instance', () async {
      String? pushed;
      await pushLoadContentDestination(
        _intent(episodeId: 'ep-empty'),
        fetch: (ref) async => _detail(ref, versions: const []),
        push: (path) => pushed = path,
      );

      expect(pushed, '/s/mydia-b/episode/ep-empty');
    });

    test('pushes nothing when no instance sent it', () async {
      String? pushed;
      await pushLoadContentDestination(
        _intent(via: null),
        fetch: (ref) async => fail('must not fetch'),
        push: (path) => pushed = path,
      );

      expect(pushed, isNull);
    });
  });

  group('routeRemoteIntent', () {
    test('a LoadContent is submitted with the instance it came through',
        () async {
      final submitted = <RemoteControlIntent>[];
      await routeRemoteIntent(
        _intent(via: null),
        'peer-1',
        instancesOf: (peer) async {
          expect(peer, 'peer-1');
          return [_a, _b];
        },
        submit: submitted.add,
      );

      expect((submitted.single as LoadContentIntent).via, _a);
    });

    test('a LoadContent from a sender no instance lists is dropped', () async {
      final submitted = <RemoteControlIntent>[];
      await routeRemoteIntent(
        _intent(via: null),
        'peer-1',
        instancesOf: (peer) async => const [],
        submit: submitted.add,
      );

      expect(submitted, isEmpty);
    });

    test('other intents pass straight through', () async {
      final submitted = <RemoteControlIntent>[];
      const pause = TransportIntent(TransportAction.pause);
      await routeRemoteIntent(
        pause,
        'peer-1',
        instancesOf: (peer) async => fail('not needed'),
        submit: submitted.add,
      );

      expect(submitted, [pause]);
    });
  });
}
