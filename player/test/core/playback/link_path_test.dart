import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart' show P2pConnectionType;
import 'package:player/core/playback/link_path.dart';

void main() {
  test('plain HTTP is always the http path, whatever p2p reports', () {
    for (final type in P2pConnectionType.values) {
      expect(linkPathFor(isP2P: false, type: type), LinkPath.http);
    }
  });

  test('p2p maps each connection type to its own path', () {
    expect(
      linkPathFor(isP2P: true, type: P2pConnectionType.direct),
      LinkPath.direct,
    );
    expect(
      linkPathFor(isP2P: true, type: P2pConnectionType.relay),
      LinkPath.relay,
    );
    expect(
      linkPathFor(isP2P: true, type: P2pConnectionType.mixed),
      LinkPath.mixed,
    );
  });

  test('p2p with no peer path yet is unknown', () {
    expect(linkPathFor(isP2P: true, type: P2pConnectionType.none), isNull);
  });
}
