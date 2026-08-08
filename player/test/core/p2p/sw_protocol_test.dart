import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/sw_protocol.dart';

void main() {
  group('SwRequest.fromMessage', () {
    test('parses a manifest request', () {
      final request = SwRequest.fromMessage({
        'type': 'p2p-request',
        'id': 'req-1',
        'path': '/hls/session-9/index.m3u8',
        'headers': <String, String>{},
      });

      expect(request.id, 'req-1');
      expect(request.path, '/hls/session-9/index.m3u8');
      expect(request.rangeStart, isNull);
      expect(request.rangeEnd, isNull);
    });

    test('parses a byte range', () {
      final request = SwRequest.fromMessage({
        'type': 'p2p-request',
        'id': 'req-2',
        'path': '/direct/file-3/stream',
        'headers': {'range': 'bytes=0-1023'},
      });

      expect(request.rangeStart, 0);
      expect(request.rangeEnd, 1023);
    });

    test('parses an open-ended byte range', () {
      final request = SwRequest.fromMessage({
        'type': 'p2p-request',
        'id': 'req-3',
        'path': '/direct/file-3/stream',
        'headers': {'range': 'bytes=2048-'},
      });

      expect(request.rangeStart, 2048);
      expect(request.rangeEnd, isNull);
    });
  });
}
