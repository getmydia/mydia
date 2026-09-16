import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';

void main() {
  group('P2pService.addAddressHint', () {
    test('is a no-op with no host, matching respondToControl', () async {
      // A hint is advisory. A service that was never initialised, or was torn
      // down since, has nothing to seed, and throwing here would make callers
      // guard a call that cannot fail meaningfully.
      final service = P2pService();
      addTearDown(service.dispose);

      await expectLater(
        service.addAddressHint('{"id":"abc","addrs":[]}'),
        completes,
      );
    });
  });
}
