import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_content.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/core/cast/cast_session_store.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/domain/sources/item.dart';

void main() {
  const device = CastDevice(
      id: 'tv-1', name: 'Den TV', protocol: CastProtocolKind.chromecast);
  final savedAt = DateTime.utc(2026, 10, 4, 12);

  test('a source record round-trips its item and version', () {
    final record = PersistedCastSession.forContent(
      device: device,
      content: const SourceCastContent(
        item: ItemRef(
            sourceId: SourceId('px1:owner:srv'),
            kind: ItemKind.episode,
            externalId: '4021'),
        versionId: '77',
      ),
      title: 'The Quiet Harbor',
      position: const Duration(seconds: 95),
      routeKind: CastRouteKind.directServer,
      savedAt: savedAt,
      mediaUrl: 'http://192.168.1.5:32400/video/x.m3u8',
    );

    final back = PersistedCastSession.fromMap(record.toMap());

    expect(back.content, record.content);
    expect(back.position, const Duration(seconds: 95));
    expect(back.mediaUrl, record.mediaUrl);
  });

  test('a record with no content kind or instance reads as the legacy Mydia',
      () {
    final back = PersistedCastSession.fromMap(
      {
        'device': device.toJson(),
        'mediaId': 'm1',
        'mediaType': 'episode',
        'fileId': 'f1',
        'showId': 's1',
        'title': 'Lanterns',
        'positionSeconds': 10,
        'routeKind': 'direct',
        'savedAt': savedAt.toIso8601String(),
      },
      legacyMydia: const SourceId('macct'),
    );

    expect(
      back.content,
      const MydiaCastContent(
          sourceId: SourceId('macct'),
          fileId: 'f1',
          mediaId: 'm1',
          mediaType: 'episode',
          showId: 's1'),
    );
  });

  test('a Mydia record still writes the legacy keys', () {
    final map = PersistedCastSession(
      sourceId: const SourceId('macct'),
      device: device,
      mediaId: 'm1',
      mediaType: 'movie',
      fileId: 'f1',
      title: 'Lanterns',
      position: Duration.zero,
      routeKind: CastRouteKind.directServer,
      savedAt: savedAt,
    ).toMap();

    expect(map['contentKind'], 'mydia');
    expect(map['mediaId'], 'm1');
    expect(map['fileId'], 'f1');
  });
}
