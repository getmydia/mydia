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
    final controllableAsync = ref.watch(remoteControlEnabledProvider);

    // `AsyncValue.value` is null both while Hive is still opening its box
    // and if opening it failed, and treating either as "true" (the old
    // behaviour) reads a device that explicitly opted out as controllable
    // for however long that takes, republishing a node id nobody asked to
    // publish. `RemoteControlSettings.controllableEnabled` only defaults to
    // true once storage has actually resolved with nothing stored, so this
    // must not race ahead of it: unresolved defaults to *not* controllable,
    // and the rebuild that follows resolution decides for real.
    final controllable = controllableAsync.value ?? false;
    final settingUnresolved = !controllableAsync.hasValue;

    // While the setting hasn't resolved, `controllable: false` above makes
    // the service go idle, which reads to the user as "you turned this
    // off" -- indistinguishable from a real opt-out. It is neither; it is
    // still loading, the same reason `RegistrationWaiting` already exists
    // for the node id and the server connection. Reclassify it the same
    // way. `RegistrationIdle` is the *only* status the service ever emits
    // while uncontrollable, so this cannot misfire on an unrelated idle.
    RegistrationStatus reportedStatus(RegistrationStatus status) {
      if (settingUnresolved && status is RegistrationIdle) {
        return const RegistrationWaiting('the remote control setting');
      }
      return status;
    }

    final subscription = service.statuses.listen((status) {
      // `cancel()` is async and does not retract an event already queued, so
      // one can arrive after this provider is gone. Same guard, same reason,
      // as `P2pStatusNotifier`.
      if (!ref.mounted) return;
      state = reportedStatus(status);
    });
    ref.onDispose(subscription.cancel);

    service.update(
      controllable: controllable,
      nodeId: p2pStatus.nodeId,
      clientReady: client != null,
      // Scopes the service's "already registered" cache to this client, so
      // signing into a different account or server on the same device (same
      // iroh node id) re-registers instead of being skipped as a no-op.
      clientScope: client,
    );

    return reportedStatus(service.status);
  }

  /// Abandons any pending backoff and tries again now.
  void retry() => ref.read(nodeRegistrationServiceProvider).retryNow();
}

final nodeRegistrationProvider =
    NotifierProvider<NodeRegistrationDriver, RegistrationStatus>(
  NodeRegistrationDriver.new,
);
