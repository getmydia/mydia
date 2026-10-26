import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_summary.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/l10n/gen/app_localizations_en.dart';
import 'package:player/l10n/l10n.dart';

final _en = AppLocalizationsEn();

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

      expect(summary.kind, ConnectionKind.server);
      expect(_en.connectionLabel(summary), 'Connected to server');
      expect(_en.connectionDetail(summary),
          'Direct connection, no relay involved');
      expect(summary.tone, ConnectionTone.good);
    });

    test('a non-p2p connection ignores the p2p fields entirely', () {
      final summary = _summary(
        isP2P: false,
        type: P2pConnectionType.relay,
        isInitialized: true,
      );

      expect(_en.connectionLabel(summary), 'Connected to server');
      expect(summary.tone, ConnectionTone.good);
    });

    test('a direct peer link is good', () {
      final summary = _summary(type: P2pConnectionType.direct);

      expect(_en.connectionLabel(summary), 'Connected directly');
      expect(_en.connectionDetail(summary),
          'Peer-to-peer link with no relay in the path');
      expect(summary.tone, ConnectionTone.good);
    });

    test('a relayed peer link warns', () {
      final summary = _summary(type: P2pConnectionType.relay);

      expect(_en.connectionLabel(summary), 'Connected through a relay');
      expect(_en.connectionDetail(summary),
          'Traffic is passing through a relay server');
      expect(summary.tone, ConnectionTone.caution);
    });

    test('a mixed peer link warns and says so plainly', () {
      final summary = _summary(type: P2pConnectionType.mixed);

      expect(_en.connectionLabel(summary), 'Partly relayed');
      expect(_en.connectionDetail(summary),
          'Some paths are direct and some go through a relay');
      expect(summary.tone, ConnectionTone.caution);
    });

    test('no connection after initialization reads as reconnecting', () {
      final summary = _summary(
        type: P2pConnectionType.none,
        isInitialized: true,
      );

      expect(_en.connectionLabel(summary), 'Reconnecting');
      expect(summary.tone, ConnectionTone.pending);
    });

    test('no connection before initialization reads as connecting', () {
      final summary = _summary(
        type: P2pConnectionType.none,
        isInitialized: false,
      );

      expect(_en.connectionLabel(summary), 'Connecting');
      expect(summary.tone, ConnectionTone.pending);
    });

    test('no label leaks the p2p jargon the old strings used', () {
      final labels = [
        _en.connectionLabel(_summary(isP2P: false)),
        for (final type in P2pConnectionType.values) ...[
          _en.connectionLabel(_summary(type: type, isInitialized: true)),
          _en.connectionLabel(_summary(type: type, isInitialized: false)),
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
        expect(_en.connectionLabel(summary), isNot(contains('—')));
        expect(_en.connectionDetail(summary), isNot(contains('—')));
      }
    });
  });
}
