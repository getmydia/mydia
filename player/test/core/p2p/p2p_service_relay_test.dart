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

  test('reset clears the configured relays so a stale list cannot linger', () {
    final service = P2pService();
    service.debugSetConfiguredRelays(const ['https://relay-one.example.test']);
    expect(service.activeRelayUrl, 'https://relay-one.example.test');

    service.reset();

    // reinitializeWithRelayUrl is reset() followed by initialize(). If reset
    // left the old list in place, the window between the two would report the
    // relay the user just replaced.
    //
    // This covers reset's own teardown only. The related race, where an
    // initialize() still awaiting resolveRelayList() publishes its host over
    // the replacement's, is guarded by _initGeneration but is not reachable
    // from here: driving _initialize past that await needs P2PHost.init and so
    // the native bridge, which the unit suite does not load. The Player E2E
    // suite is what exercises it.
    expect(service.activeRelayUrl, isNull);
  });
}
