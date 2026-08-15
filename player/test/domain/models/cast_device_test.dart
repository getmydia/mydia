import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/cast_device.dart';

void main() {
  group('CastDevice', () {
    const device = CastDevice(
      id: 'abc123',
      name: 'Living Room TV',
      protocol: CastProtocolKind.chromecast,
      model: 'Chromecast Ultra',
      host: '192.168.1.50',
      port: 8009,
      metadata: {'md': 'Chromecast Ultra', 'id': 'abc123'},
    );

    test('round-trips through JSON', () {
      final restored = CastDevice.fromJson(device.toJson());

      expect(restored.id, device.id);
      expect(restored.name, device.name);
      expect(restored.protocol, CastProtocolKind.chromecast);
      expect(restored.model, device.model);
      expect(restored.host, device.host);
      expect(restored.port, device.port);
      expect(restored.metadata, device.metadata);
    });

    test('defaults metadata to empty when absent from JSON', () {
      final restored = CastDevice.fromJson(const {
        'id': 'x',
        'name': 'y',
        'protocol': 'chromecast',
      });

      expect(restored.metadata, isEmpty);
    });

    test('round-trips DLNA control-URL metadata needed to reconnect', () {
      const dlna = CastDevice(
        id: 'uuid:1',
        name: 'Bedroom TV',
        protocol: CastProtocolKind.dlna,
        host: '192.168.1.51',
        port: 1900,
        metadata: {
          'avTransportControlUrl':
              'http://192.168.1.51:1900/AVTransport/control',
          'renderingControlUrl':
              'http://192.168.1.51:1900/RenderingControl/control',
        },
      );

      final restored = CastDevice.fromJson(dlna.toJson());

      expect(
        restored.metadata['avTransportControlUrl'],
        'http://192.168.1.51:1900/AVTransport/control',
      );
      expect(
        restored.metadata['renderingControlUrl'],
        'http://192.168.1.51:1900/RenderingControl/control',
      );
    });

    test('round-trips a DLNA device', () {
      const dlna = CastDevice(
        id: 'uuid:1',
        name: 'Bedroom TV',
        protocol: CastProtocolKind.dlna,
      );

      expect(
          CastDevice.fromJson(dlna.toJson()).protocol, CastProtocolKind.dlna);
    });

    test('falls back to chromecast for an unknown protocol string', () {
      final restored = CastDevice.fromJson(const {
        'id': 'x',
        'name': 'y',
        'protocol': 'satellite',
      });

      expect(restored.protocol, CastProtocolKind.chromecast);
    });

    test('equality is by id', () {
      const other = CastDevice(
        id: 'abc123',
        name: 'Renamed',
        protocol: CastProtocolKind.dlna,
      );

      expect(device, equals(other));
    });
  });

  group('CastSubtitleTrack.isServableTrackId', () {
    // Mirrors `Mydia.Streaming.SessionSubtitles`'s `@filename_pattern`: an
    // ffprobe stream index (digits) or a sidecar UUID, and nothing else.
    // `CastRouteResolver._sessionSubtitles` builds `subs_<trackId>.vtt` from
    // whatever id it is handed with no validation of its own, so an id this
    // predicate wrongly admits reaches the server as a URL that 404s.

    test('accepts a numeric ffprobe stream index', () {
      expect(CastSubtitleTrack.isServableTrackId('3'), isTrue);
      expect(CastSubtitleTrack.isServableTrackId('0'), isTrue);
      expect(CastSubtitleTrack.isServableTrackId('42'), isTrue);
    });

    test('accepts a sidecar uuid', () {
      expect(
        CastSubtitleTrack.isServableTrackId(
          '0f8fad5b-d9cb-469f-a165-70867728950e',
        ),
        isTrue,
      );
    });

    test('rejects a media_kit synthetic id', () {
      // Built in `PlayerScreen._detectTracks` for every embedded track in a
      // direct-play session (`id: 'mk_${mkTrack.id}'`). The server has never
      // heard of this id; offering it to a receiver is exactly the
      // regression this predicate exists to prevent.
      expect(CastSubtitleTrack.isServableTrackId('mk_0'), isFalse);
      expect(CastSubtitleTrack.isServableTrackId('mk_12'), isFalse);
    });

    test('rejects other non-conforming shapes', () {
      expect(CastSubtitleTrack.isServableTrackId(''), isFalse);
      expect(CastSubtitleTrack.isServableTrackId('trk-1'), isFalse);
      expect(CastSubtitleTrack.isServableTrackId('3 '), isFalse);
      expect(CastSubtitleTrack.isServableTrackId(' 3'), isFalse);
      expect(CastSubtitleTrack.isServableTrackId('3\n'), isFalse);
    });
  });
}
