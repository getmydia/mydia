import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/domain/models/cast_device.dart';

void main() {
  group('CastMediaRequest', () {
    test('carries a content reference instead of a URL for a Mydia target', () {
      const request = CastMediaRequest(
        url: '',
        kind: CastMediaKind.hls,
        title: 'Blade Runner',
        contentRef: MydiaContentRef(
          mediaItemId: 'item-1',
          episodeId: null,
          audioTrack: null,
          subtitleTrack: null,
        ),
      );

      expect(request.contentRef, isNotNull);
      expect(request.contentRef!.mediaItemId, 'item-1');
    });

    test(
        'leaves the content reference null for a Chromecast, which needs a URL',
        () {
      const request = CastMediaRequest(
        url: 'https://example.test/index.m3u8',
        kind: CastMediaKind.hls,
        title: 'Blade Runner',
      );

      expect(request.contentRef, isNull);
      expect(request.url, isNotEmpty);
    });
  });

  group('CastProtocolKind', () {
    test('round-trips mydia through CastDevice serialization', () {
      const device = CastDevice(
        id: 'node-a',
        name: 'Living Room',
        protocol: CastProtocolKind.mydia,
        metadata: {'nodeId': 'node-a'},
      );

      final restored = CastDevice.fromJson(device.toJson());

      expect(restored.protocol, CastProtocolKind.mydia);
      expect(restored.metadata['nodeId'], 'node-a');
    });
  });
}
