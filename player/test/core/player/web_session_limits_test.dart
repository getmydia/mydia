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
}
