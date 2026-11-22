import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/media_route.dart';

void main() {
  test('an artwork URL round-trips to its session', () {
    final url =
        MediaRoutes.artwork('http://127.0.0.1:9/t/acc', 'abc-0123abcd.png');
    expect(url, 'http://127.0.0.1:9/t/acc/artwork/abc-0123abcd.png');
    final m =
        MediaRoutes.resolve('/artwork/abc-0123abcd.png') as MediaRouteMatch;
    expect(m.sessionId, 'artwork:abc-0123abcd.png');
    expect(m.path, 'file');
    expect(m.kind, MediaRouteKind.hls);
  });

  test('an artwork path with no file is a 400', () {
    expect((MediaRoutes.resolve('/artwork/') as MediaRouteFailure).statusCode,
        400);
  });
}
