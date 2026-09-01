import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../graphql/graphql_provider.dart';
import '../p2p/p2p_service.dart';
import 'node_registration.dart';
import 'node_registration_service.dart';
import 'registration_status.dart';
import 'remote_control_settings.dart';

/// One service for the app's lifetime.
///
/// The `register` callback resolves the GraphQL client per attempt rather than
/// capturing one, so a token refresh or a switch between direct and p2p mode
/// is picked up by the next retry instead of pinning a stale client.
final nodeRegistrationServiceProvider =
    Provider<NodeRegistrationService>((ref) {
  final service = NodeRegistrationService(
    register: (nodeId) async {
      final client = await ref.read(asyncGraphqlClientProvider.future);
      return NodeRegistration(
        client: client,
        nodeId: () async => nodeId,
      ).register();
    },
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Feeds [nodeRegistrationServiceProvider] from its three watched inputs and
/// republishes its status as provider state.
///
/// `build()` re-runs whenever any input changes, which is the whole point: the
/// previous implementation sampled these once during startup and gave up for
/// the rest of the session if any of them had not arrived yet.
class NodeRegistrationDriver extends Notifier<RegistrationStatus> {
  @override
  RegistrationStatus build() {
    final service = ref.watch(nodeRegistrationServiceProvider);
    final p2pStatus = ref.watch(p2pStatusNotifierProvider);
    final client = ref.watch(graphqlClientProvider);
    // Defaults to true to match `RemoteControlSettings.controllableEnabled`,
    // so a device is not treated as opted out merely because Hive has not
    // finished opening its box.
    final controllable = ref.watch(remoteControlEnabledProvider).value ?? true;

    final subscription = service.statuses.listen((status) {
      // `cancel()` is async and does not retract an event already queued, so
      // one can arrive after this provider is gone. Same guard, same reason,
      // as `P2pStatusNotifier`.
      if (!ref.mounted) return;
      state = status;
    });
    ref.onDispose(subscription.cancel);

    service.update(
      controllable: controllable,
      nodeId: p2pStatus.nodeId,
      clientReady: client != null,
    );

    return service.status;
  }

  /// Abandons any pending backoff and tries again now.
  void retry() => ref.read(nodeRegistrationServiceProvider).retryNow();
}

final nodeRegistrationProvider =
    NotifierProvider<NodeRegistrationDriver, RegistrationStatus>(
  NodeRegistrationDriver.new,
);
