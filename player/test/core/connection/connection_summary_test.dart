import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_summary.dart';
import 'package:player/core/p2p/p2p_service.dart';

ConnectionSummary _summary({
  bool isP2P = true,
  P2pConnectionType type = P2pConnectionType.none,
  bool isInitialized = false,
}) =>
    ConnectionSummary.from(
      isP2P: isP2P,
      type: type,
      isInitialized: isInitialized,
    );

void main() {
  group('ConnectionSummary.from', () {
    test('a non-p2p connection reads as a plain server connection', () {
      final summary = _summary(isP2P: false);

      expect(summary.label, 'Connected to server');
      expect(summary.detail, 'Direct connection, no relay involved');
      expect(summary.tone, ConnectionTone.good);
    });

    test('a non-p2p connection ignores the p2p fields entirely', () {
      final summary = _summary(
        isP2P: false,
        type: P2pConnectionType.relay,
        isInitialized: true,
      );

      expect(summary.label, 'Connected to server');
      expect(summary.tone, ConnectionTone.good);
    });

    test('a direct peer link is good', () {
      final summary = _summary(type: P2pConnectionType.direct);

      expect(summary.label, 'Connected directly');
      expect(summary.detail, 'Peer-to-peer link with no relay in the path');
      expect(summary.tone, ConnectionTone.good);
    });

    test('a relayed peer link warns', () {
      final summary = _summary(type: P2pConnectionType.relay);

      expect(summary.label, 'Connected through a relay');
      expect(summary.detail, 'Traffic is passing through a relay server');
      expect(summary.tone, ConnectionTone.caution);
    });

    test('a mixed peer link warns and says so plainly', () {
      final summary = _summary(type: P2pConnectionType.mixed);

      expect(summary.label, 'Partly relayed');
      expect(
          summary.detail, 'Some paths are direct and some go through a relay');
      expect(summary.tone, ConnectionTone.caution);
    });

    test('no connection after initialization reads as reconnecting', () {
      final summary = _summary(
        type: P2pConnectionType.none,
        isInitialized: true,
      );

      expect(summary.label, 'Reconnecting');
      expect(summary.tone, ConnectionTone.pending);
    });

    test('no connection before initialization reads as connecting', () {
      final summary = _summary(
        type: P2pConnectionType.none,
        isInitialized: false,
      );

      expect(summary.label, 'Connecting');
      expect(summary.tone, ConnectionTone.pending);
    });

    test('no label leaks the p2p jargon the old strings used', () {
      final labels = [
        _summary(isP2P: false).label,
        for (final type in P2pConnectionType.values) ...[
          _summary(type: type, isInitialized: true).label,
          _summary(type: type, isInitialized: false).label,
        ],
      ];

      for (final label in labels) {
        expect(label.toLowerCase(), isNot(contains('p2p')));
        expect(label, isNot(contains('(')));
      }
    });

    test('no copy uses an em dash', () {
      for (final type in P2pConnectionType.values) {
        final summary = _summary(type: type);
        expect(summary.label, isNot(contains('—')));
        expect(summary.detail, isNot(contains('—')));
      }
    });
  });
}
