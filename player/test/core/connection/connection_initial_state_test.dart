import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart';

void main() {
  test('build returns the startup-provided p2p state synchronously', () {
    final container = ProviderContainer(overrides: [
      initialConnectionStateProvider.overrideWithValue(
        ConnectionState.p2p(serverNodeAddr: '{"id":"node-1"}', relayUrl: null),
      ),
    ]);
    addTearDown(container.dispose);

    final state = container.read(connectionProvider);
    expect(state.isP2PMode, isTrue);
    expect(state.serverNodeAddr, '{"id":"node-1"}');
  });

  test('without a startup state it starts direct, as before', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(connectionProvider).isP2PMode, isFalse);
  });
}
