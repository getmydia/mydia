import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/remote/node_registration_providers.dart';
import 'package:player/core/remote/node_registration_service.dart';
import 'package:player/core/remote/registration_status.dart';
import 'package:player/core/remote/remote_control_settings.dart';

import '../../test_utils/stub_graphql_client.dart';

void main() {
  group('nodeRegistrationProvider', () {
    test('registers when the node id arrives after the first build', () async {
      final sent = <String>[];
      final statusNotifier = _FakeP2pStatus();

      final container = ProviderContainer(overrides: [
        nodeRegistrationServiceProvider.overrideWith((ref) {
          final service = NodeRegistrationService(
            register: (nodeId) async {
              sent.add(nodeId);
              return true;
            },
            delay: (_) async {},
          );
          ref.onDispose(service.dispose);
          return service;
        }),
        p2pStatusNotifierProvider.overrideWith(() => statusNotifier),
        remoteControlEnabledProvider.overrideWith((ref) async => true),
        // A real GraphQLClient over a stub link. The driver only checks this
        // for null, and the service above never reaches it, but it has to be
        // non-null for `clientReady` to be true.
        graphqlClientProvider.overrideWith(
          (ref) => stubClient(StubLink.responses([
            <String, dynamic>{'__typename': 'Mutation'},
          ])),
        ),
      ]);
      addTearDown(container.dispose);

      // Keep the driver alive for the whole test.
      container.listen(nodeRegistrationProvider, (_, __) {});
      await container.read(remoteControlEnabledProvider.future);
      await pumpEventQueue();

      expect(sent, isEmpty,
          reason: 'no node id yet, so there is nothing to publish');
      expect(
          container.read(nodeRegistrationProvider), isA<RegistrationWaiting>());

      statusNotifier.publish('a' * 64);
      await pumpEventQueue();

      expect(sent, ['a' * 64],
          reason: 'the late node id must drive a registration, not be missed');
      expect(container.read(nodeRegistrationProvider),
          isA<RegistrationSucceeded>());
    });
  });
}

/// Publishes a node id on demand so a test can decide when the host appears.
///
/// The single instance is deliberately captured and reused so `publish` can
/// reach it. That is safe only because the provider is built once per test: a
/// Riverpod `Notifier` instance cannot be mounted twice, so a test that lets
/// this provider be disposed and rebuilt must hand `overrideWith` a factory
/// that constructs a fresh one instead.
class _FakeP2pStatus extends P2pStatusNotifier {
  @override
  P2pStatus build() => const P2pStatus.initial();

  void publish(String nodeId) {
    state = const P2pStatus.initial().copyWith(
      isInitialized: true,
      nodeId: nodeId,
    );
  }
}
