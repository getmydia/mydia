import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/p2p/relay_list.dart';

void main() {
  test('the compiled-in default is the relay this build ships with', () {
    // p2p_service.dart used to own this constant. relay_list.dart owns it now,
    // and p2p_service re-exports it so existing importers keep working.
    expect(defaultRelayUrl, defaultIrohRelayUrl);
    expect(defaultRelayUrl, 'https://cae1-1.relay.mydia.dev');
  });

  test('an uninitialized service reports no active relay', () {
    final service = P2pService();
    expect(service.activeRelayUrl, isNull);
    expect(service.status.relayUrl, isNull);
  });

  test('the configured list is reported before the ready event arrives', () {
    final service = P2pService();
    service.debugSetConfiguredRelays(const [
      'https://relay-one.example.test',
      'https://relay-two.example.test',
    ]);

    // activeRelayUrl prefers the relay the node actually landed on, which only
    // the ready: event knows. Until then, the first configured relay is the
    // honest answer.
    expect(service.activeRelayUrl, 'https://relay-one.example.test');
  });
}
