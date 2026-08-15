import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/core/cast/cast_session_store.dart';
import 'package:player/domain/models/cast_device.dart';

void main() {
  PersistedCastSession sessionAt(DateTime savedAt) => PersistedCastSession(
        device: const CastDevice(
          id: 'd1',
          name: 'Living Room',
          protocol: CastProtocolKind.chromecast,
          host: '192.168.1.50',
          port: 8009,
          metadata: {'md': 'Chromecast Ultra'},
        ),
        mediaId: 'movie-9',
        mediaType: 'movie',
        fileId: 'file-3',
        title: 'Arrival',
        position: const Duration(minutes: 12),
        routeKind: CastRouteKind.directServer,
        savedAt: savedAt,
      );

  group('PersistedCastSession', () {
    test('round-trips through a map', () {
      final original = sessionAt(DateTime.utc(2026, 7, 28, 10));
      final restored = PersistedCastSession.fromMap(original.toMap());

      expect(restored.device.id, 'd1');
      expect(restored.device.protocol, CastProtocolKind.chromecast);
      expect(restored.mediaId, 'movie-9');
      expect(restored.mediaType, 'movie');
      expect(restored.fileId, 'file-3');
      expect(restored.title, 'Arrival');
      expect(restored.position, const Duration(minutes: 12));
      expect(restored.routeKind, CastRouteKind.directServer);
      expect(restored.savedAt, DateTime.utc(2026, 7, 28, 10));
      expect(restored.device.metadata['md'], 'Chromecast Ultra');
    });

    test('is not expired within 12 hours', () {
      final session = sessionAt(DateTime.utc(2026, 7, 28, 10));

      expect(session.isExpired(DateTime.utc(2026, 7, 28, 21)), isFalse);
    });

    test('is expired after 12 hours', () {
      final session = sessionAt(DateTime.utc(2026, 7, 28, 10));

      expect(session.isExpired(DateTime.utc(2026, 7, 28, 23)), isTrue);
    });

    test('preserves the bridge route kind', () {
      final original = PersistedCastSession(
        device: const CastDevice(
          id: 'd2',
          name: 'Bedroom',
          protocol: CastProtocolKind.dlna,
        ),
        mediaId: 'ep-1',
        mediaType: 'episode',
        fileId: 'file-4',
        title: 'Pilot',
        position: Duration.zero,
        routeKind: CastRouteKind.localBridge,
        savedAt: DateTime.utc(2026, 7, 28),
      );

      expect(
        PersistedCastSession.fromMap(original.toMap()).routeKind,
        CastRouteKind.localBridge,
      );
    });
  });

  group('selected subtitle track', () {
    test('round-trips through storage', () {
      final session = PersistedCastSession(
        device: const CastDevice(
          id: 'd1',
          name: 'Living Room',
          protocol: CastProtocolKind.chromecast,
        ),
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'A Movie',
        position: const Duration(minutes: 5),
        routeKind: CastRouteKind.directServer,
        savedAt: DateTime.utc(2026, 8, 15),
        selectedSubtitleTrackId: '3',
      );

      final restored = PersistedCastSession.fromMap(session.toMap());
      expect(restored.selectedSubtitleTrackId, '3');
    });

    test('a record written before this field existed restores with none', () {
      // `.toMap()..remove(...)` rather than passing `null` explicitly: the
      // point is a real record from before this field existed, where the key
      // is absent entirely, not merely set to null.
      final map = PersistedCastSession(
        device: const CastDevice(
          id: 'd1',
          name: 'Living Room',
          protocol: CastProtocolKind.chromecast,
        ),
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'A Movie',
        position: Duration.zero,
        routeKind: CastRouteKind.directServer,
        savedAt: DateTime.utc(2026, 8, 15),
      ).toMap()
        ..remove('selectedSubtitleTrackId');

      expect(map.containsKey('selectedSubtitleTrackId'), isFalse);
      expect(
        PersistedCastSession.fromMap(map).selectedSubtitleTrackId,
        isNull,
      );
    });

    test('copyWith replaces the id', () {
      final session = PersistedCastSession(
        device: const CastDevice(
          id: 'd1',
          name: 'Living Room',
          protocol: CastProtocolKind.chromecast,
        ),
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'A Movie',
        position: Duration.zero,
        routeKind: CastRouteKind.directServer,
        savedAt: DateTime.utc(2026, 8, 15),
        selectedSubtitleTrackId: '2',
      );

      expect(
          session
              .copyWith(selectedSubtitleTrackId: '3')
              .selectedSubtitleTrackId,
          '3');
      // Omitting the argument must leave the existing choice alone, matching
      // every other field this copyWith carries.
      expect(
          session
              .copyWith(position: const Duration(minutes: 1))
              .selectedSubtitleTrackId,
          '2');
      // Turning subtitles back off needs an unambiguous way to reach null,
      // since a bare `selectedSubtitleTrackId: null` argument is what "leave
      // unchanged" already looks like.
      expect(
        session.copyWith(clearSelectedSubtitle: true).selectedSubtitleTrackId,
        isNull,
      );
    });
  });

  group('InMemoryCastSessionStore', () {
    test('saves, loads and clears', () async {
      final store = InMemoryCastSessionStore();
      expect(await store.load(), isNull);

      await store.save(sessionAt(DateTime.utc(2026, 7, 28)));
      expect((await store.load())?.mediaId, 'movie-9');

      await store.clear();
      expect(await store.load(), isNull);
    });
  });

  group('HiveCastSessionStore', () {
    late Directory tempDir;
    late Box<Map> box;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cast_store_test');
      Hive.init(tempDir.path);
      box = await Hive.openBox<Map>('cast_session_test');
    });

    tearDown(() async {
      await box.deleteFromDisk();
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    test('persists across store instances backed by the same box', () async {
      await HiveCastSessionStore(box)
          .save(sessionAt(DateTime.utc(2026, 7, 28)));

      final loaded = await HiveCastSessionStore(box).load();

      expect(loaded?.device.name, 'Living Room');
      expect(loaded?.position, const Duration(minutes: 12));
      // Hive round-trips nested maps as Map<dynamic, dynamic>, not
      // Map<String, dynamic> — this is the path that matters for
      // reconstructDartCastDevice, which reads this back after a fresh
      // app launch to reconnect without a discovery sweep.
      expect(loaded?.device.metadata['md'], 'Chromecast Ultra');
    });

    test('load returns null after clear', () async {
      final store = HiveCastSessionStore(box);
      await store.save(sessionAt(DateTime.utc(2026, 7, 28)));
      await store.clear();

      expect(await store.load(), isNull);
    });

    test('load returns null when the stored map is malformed', () async {
      await box.put('session', {'garbage': true});

      expect(await HiveCastSessionStore(box).load(), isNull);
    });
  });
}
