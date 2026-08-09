import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/web_session_limits.dart';

void main() {
  group('webSessionLimits', () {
    test('caps a relayed session', () {
      final limits = webSessionLimits(relayed: true);
      expect(limits.maxBitrate, kWebMaxBitrateKbps);
      expect(limits.maxHeight, kWebMaxHeight);
    });

    test('leaves an unrelayed session uncapped', () {
      // The instance-hosted /player build talks to its own origin over HTTP
      // and costs us no relay bandwidth, so it must not be degraded.
      final limits = webSessionLimits(relayed: false);
      expect(limits.maxBitrate, isNull);
      expect(limits.maxHeight, isNull);
    });
  });

  group('tighterCap', () {
    test('both null stays uncapped', () {
      expect(tighterCap(null, null), isNull);
    });

    test('no request falls back to the ceiling', () {
      expect(tighterCap(null, 720), 720);
    });

    test('no ceiling falls back to the request', () {
      expect(tighterCap(1080, null), 1080);
    });

    test('both present, request below ceiling: the request wins', () {
      expect(tighterCap(480, 720), 480);
    });

    test('both present, ceiling below request: the ceiling wins', () {
      expect(tighterCap(1080, 720), 720);
    });
  });
}
