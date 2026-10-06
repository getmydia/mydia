import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/remote/node_registration_providers.dart';
import 'package:player/core/remote/node_registration_service.dart';
import 'package:player/core/remote/registration_status.dart';
import 'package:player/core/remote/remote_control_settings.dart';
import 'package:player/core/sources/mydia/bound_mydia.dart';
import 'package:player/core/sources/mydia/mydia_client.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/graphql/queries/online_devices.graphql.dart';

import '../sources/mydia/fake_mydia_client.dart';
import '../sources/mydia/fake_mydia_transport.dart';

/// Which account the app has bound, switchable mid-test.
class _Binding extends Notifier<({String? accountId, MydiaClient? client})> {
  _Binding(this._initial);

  final ({String? accountId, MydiaClient? client}) _initial;

  @override
  ({String? accountId, MydiaClient? client}) build() => _initial;

  void bind(String accountId, MydiaClient client) =>
      state = (accountId: accountId, client: client);
}

void main() {
  group('against the real service and a server', () {
    late FakeMydiaTransport server;
    late _FakeP2pStatus statusNotifier;
    late NotifierProvider<_Binding, ({String? accountId, MydiaClient? client})>
        binding;
    late ProviderContainer container;

    int registrations() =>
        server.calls.where((c) => c.operation == 'RegisterDeviceNode').length;

    MydiaClient clientFor(String instanceId) => fakeMydiaClient(
          server,
          creds: MydiaCredentials(
            instanceId: instanceId,
            accessToken: 'access',
            deviceToken: 'device',
          ),
        );

    setUp(() {
      server = FakeMydiaTransport();
      server.validTokens = {'access', 'fresh'};
      server.handlers['RegisterDeviceNode'] = (vars) => {
            'registerDeviceNode': {'id': 'd', 'nodeId': vars['nodeId']},
          };
      server.handlers['Devices'] = (_) => {'devices': <Object>[]};
      server.handlers['RefreshAccessToken'] = (_) => {
            'refreshAccessToken': {'token': 'fresh'},
          };
      statusNotifier = _FakeP2pStatus();
      binding = NotifierProvider<_Binding,
          ({String? accountId, MydiaClient? client})>(
        () => _Binding((accountId: 'account-a', client: clientFor('a'))),
      );
      container = ProviderContainer(overrides: [
        p2pStatusNotifierProvider.overrideWith(() => statusNotifier),
        remoteControlEnabledProvider.overrideWith((ref) async => true),
        boundAccountIdProvider
            .overrideWith((ref) => ref.watch(binding).accountId),
        boundMydiaClientProvider
            .overrideWith((ref) => ref.watch(binding).client),
      ]);
      addTearDown(container.dispose);
    });

    test('a token refresh on the bound account does not register again',
        () async {
      container.listen(nodeRegistrationProvider, (_, __) {});
      await container.read(remoteControlEnabledProvider.future);
      statusNotifier.publish('a' * 64);
      await pumpEventQueue();
      expect(registrations(), 1);

      // The access token the server accepts moves on, so an unrelated request
      // is refused, refreshed and retried.
      final client = container.read(boundMydiaClientProvider)!;
      server.validTokens = {'fresh'};
      await client.request(documentNodeQueryDevices);
      await pumpEventQueue();

      expect(
          server.calls.any((c) => c.operation == 'RefreshAccessToken'), isTrue);
      expect(registrations(), 1,
          reason: 'the same account refreshed its token, nothing to re-send');
    });

    test('binding another account registers again', () async {
      container.listen(nodeRegistrationProvider, (_, __) {});
      await container.read(remoteControlEnabledProvider.future);
      statusNotifier.publish('a' * 64);
      await pumpEventQueue();
      expect(registrations(), 1);

      container.read(binding.notifier).bind('account-b', clientFor('b'));
      await pumpEventQueue();

      expect(registrations(), 2);
    });
  });

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
        // The driver only checks this for null, and the service above never
        // reaches the client, but an account has to be bound for
        // `clientReady` to be true.
        boundAccountIdProvider.overrideWithValue('account-a'),
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

    test(
        'a stored false resolving after a loading period does not '
        'register', () async {
      final sent = <String>[];
      final statusNotifier = _FakeP2pStatus();
      final controllableCompleter = Completer<bool>();

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
        // Never resolves until the test says so, standing in for Hive still
        // opening its box.
        remoteControlEnabledProvider
            .overrideWith((ref) => controllableCompleter.future),
        boundAccountIdProvider.overrideWithValue('account-a'),
      ]);
      addTearDown(container.dispose);

      // Keep the driver alive for the whole test.
      container.listen(nodeRegistrationProvider, (_, __) {});
      // The node id and the client are both ready; only the setting is
      // still loading, so it alone must be what gates registration.
      statusNotifier.publish('a' * 64);
      await pumpEventQueue();

      expect(sent, isEmpty,
          reason: 'the setting has not resolved yet, so nothing may '
              'register even though every other input is ready');
      expect(
          container.read(nodeRegistrationProvider), isA<RegistrationWaiting>());

      controllableCompleter.complete(false);
      await pumpEventQueue();

      expect(sent, isEmpty,
          reason: 'a stored false resolving after loading must not have '
              'been treated as enabled during the loading window');
      expect(container.read(nodeRegistrationProvider), isA<RegistrationIdle>());
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
