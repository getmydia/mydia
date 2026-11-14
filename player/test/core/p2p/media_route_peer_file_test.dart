import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/media_route.dart';

/// Decodes a base64url token sent without its padding.
String _decode(String token) =>
    utf8.decode(base64Url.decode(base64Url.normalize(token)));

void main() {
  const base = 'http://127.0.0.1:4000/t/peer_0123456789ab';

  test('peer_file_route_round_trips', () {
    for (final path in [
      '/media/A Film (2031)/a #1?.mkv',
      r'C:\Movies\Žluť.mkv',
      '/x/y z.srt',
    ]) {
      final url = MediaRoutes.peerFile(base, 'flocal', path);
      expect(url, startsWith('$base/peerfile/flocal/'));
      expect(url, endsWith('/stream'));
      final token = url.split('/')[url.split('/').length - 2];
      expect(token, isNot(contains('=')), reason: 'no padding');
      expect(token, matches(RegExp(r'^[A-Za-z0-9_-]+$')));

      final route = MediaRoutes.resolve(url.substring(base.length));
      expect(route, isA<MediaRouteMatch>());
      final match = route as MediaRouteMatch;
      expect(match.sessionId, 'peerfile:flocal');
      expect(match.kind, MediaRouteKind.byteStream);
      expect(match.path, token);
      expect(_decode(match.path), path);
    }
  });

  test('a peer file route without its token is refused', () {
    expect(MediaRoutes.resolve('/peerfile/flocal/stream'),
        isA<MediaRouteFailure>());
    expect(MediaRoutes.resolve('/peerfile/flocal//stream'),
        isA<MediaRouteFailure>());
  });

  test('direct and download routes keep their fixed remote paths', () {
    final direct = MediaRoutes.resolve('/direct/f1/stream') as MediaRouteMatch;
    expect((direct.sessionId, direct.path), ('direct:f1', 'stream'));
    final download =
        MediaRoutes.resolve('/download/j1/file') as MediaRouteMatch;
    expect((download.sessionId, download.path), ('download:j1', 'file'));
  });
}
