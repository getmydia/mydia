import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/native/lib.dart';

import '../../test_utils/stub_graphql_client.dart';

/// A P2PHost-typed value for tests. None of its methods are called: the
/// providers under test only check `host != null` and hand it to a
/// transport they never drive here.
class _FakeP2PHost implements P2PHost {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$_FakeP2PHost: ${invocation.memberName}');
}

/// A `P2pService` whose host is already up. `nodeId` is deliberately left
/// at its default (null), which is the point of this fake: the pre-fix
/// providers read `selfNodeId` from this getter, so a host being present
/// here is not enough on its own to produce a backend.
class _FakeP2pServiceWithHost extends P2pService {
  final P2PHost _host = _FakeP2PHost();

  @override
  P2PHost? get host => _host;
}

/// Publishes a node id on demand so a test can decide when the host
/// finishes announcing its identity, matching the pattern in
/// `test/core/remote/node_registration_providers_test.dart`.
class _FakeP2pStatusNotifier extends P2pStatusNotifier {
  @override
  P2pStatus build() => const P2pStatus.initial();

  void publish(String nodeId) {
    state = const P2pStatus.initial().copyWith(
      isInitialized: true,
      nodeId: nodeId,
    );
  }

  /// A peer connecting, which is what `_emitStatus` broadcasts on every
  /// `connected:` event. The identity is unchanged: only the peer count and
  /// the connection type move.
  void publishPeerConnected(String nodeId) {
    state = const P2pStatus.initial().copyWith(
      isInitialized: true,
      nodeId: nodeId,
      connectedPeersCount: 1,
      peerConnectionType: P2pConnectionType.relay,
    );
  }

  /// The node becoming ready: the identity is unchanged, only the address it
  /// can be reached at arrives.
  void publishAddr(String nodeId, String nodeAddr) {
    state = const P2pStatus.initial().copyWith(
      isInitialized: true,
      nodeId: nodeId,
      nodeAddr: nodeAddr,
    );
  }
}

Map<String, dynamic> _device(String id, String nodeId,
        {required bool online}) =>
    {
      '__typename': 'RemoteDevice',
      'id': id,
      'deviceName': id,
      'platform': 'android',
      'nodeId': nodeId,
      'isRevoked': false,
      'online': online,
    };

void main() {
  group('mydiaCastBackendProvider rebuild on host swap', () {
    test(
        'stays null until the status record carries a node id, then '
        'rebuilds non-null once it does', () async {
      final statusNotifier = _FakeP2pStatusNotifier();

      final container = ProviderContainer(overrides: [
        p2pServiceProvider.overrideWithValue(_FakeP2pServiceWithHost()),
        p2pStatusNotifierProvider.overrideWith(() => statusNotifier),
        graphqlClientProvider.overrideWith(
          (ref) => stubClient(StubLink.responses([
            <String, dynamic>{'__typename': 'Query'},
          ])),
        ),
      ]);
      addTearDown(container.dispose);

      expect(
        container.read(mydiaCastBackendProvider),
        isNull,
        reason: 'the host is up but no node id has been published yet',
      );

      statusNotifier.publish('a' * 64);

      expect(
        container.read(mydiaCastBackendProvider),
        isNotNull,
        reason: 'the host and the node id are both present now, so the '
            'provider must rebuild rather than keep handing out the '
            'earlier null',
      );
    });

    test('a peer connecting does not swap the backend out mid-session',
        () async {
      // Connecting to a Mydia target is itself a peer connection, so the
      // status record moves the moment a cast session opens. Rebuilding on
      // that disposes the very backend that just sent `Hello`: `connect`
      // returns at its `if (_disposed) return`, polling never starts, and
      // the adopted session sits at a zero duration forever. Only an
      // identity change is a real host swap.
      final statusNotifier = _FakeP2pStatusNotifier();

      final container = ProviderContainer(overrides: [
        p2pServiceProvider.overrideWithValue(_FakeP2pServiceWithHost()),
        p2pStatusNotifierProvider.overrideWith(() => statusNotifier),
        graphqlClientProvider.overrideWith(
          (ref) => stubClient(StubLink.responses([
            <String, dynamic>{'__typename': 'Query'},
          ])),
        ),
      ]);
      addTearDown(container.dispose);

      // Read once before publishing: the notifier has to be mounted before
      // it can set state, exactly as the test above does.
      expect(container.read(mydiaCastBackendProvider), isNull);

      statusNotifier.publish('a' * 64);
      final before = container.read(mydiaCastBackendProvider);
      expect(before, isNotNull);

      statusNotifier.publishPeerConnected('a' * 64);

      expect(
        identical(container.read(mydiaCastBackendProvider), before),
        isTrue,
        reason: 'the same host and identity must keep the same backend, or '
            'the live session it is holding is disposed underneath it',
      );
    });

    test('the node address arriving does not swap the backend', () async {
      final statusNotifier = _FakeP2pStatusNotifier();

      final container = ProviderContainer(overrides: [
        p2pServiceProvider.overrideWithValue(_FakeP2pServiceWithHost()),
        p2pStatusNotifierProvider.overrideWith(() => statusNotifier),
        graphqlClientProvider.overrideWith(
          (ref) => stubClient(StubLink.responses([
            <String, dynamic>{'__typename': 'Query'},
          ])),
        ),
      ]);
      addTearDown(container.dispose);

      expect(container.read(mydiaCastBackendProvider), isNull);
      statusNotifier.publish('a' * 64);
      final before = container.read(mydiaCastBackendProvider);
      expect(before, isNotNull);

      statusNotifier.publishAddr('a' * 64, '{"id":"${'a' * 64}","addrs":[]}');

      expect(
          identical(container.read(mydiaCastBackendProvider), before), isTrue,
          reason: 'the provider never reads nodeAddr');
    });
  });

  group('ambientTargetsProvider rebuild on host swap', () {
    test(
        'stays null until the status record carries a node id, then '
        'rebuilds non-null once it does', () async {
      final statusNotifier = _FakeP2pStatusNotifier();

      final container = ProviderContainer(overrides: [
        p2pServiceProvider.overrideWithValue(_FakeP2pServiceWithHost()),
        p2pStatusNotifierProvider.overrideWith(() => statusNotifier),
        graphqlClientProvider.overrideWith(
          (ref) => stubClient(StubLink.responses([
            <String, dynamic>{'__typename': 'Query'},
          ])),
        ),
      ]);
      addTearDown(container.dispose);

      expect(
        container.read(ambientTargetsProvider),
        isNull,
        reason: 'the host is up but no node id has been published yet',
      );

      statusNotifier.publish('a' * 64);

      expect(
        container.read(ambientTargetsProvider),
        isNotNull,
        reason: 'the host and the node id are both present now, so the '
            'provider must rebuild rather than keep handing out the '
            'earlier null',
      );
    });

    test('a peer connecting does not dispose the held ambient targets',
        () async {
      // Ambient awareness holds a live connection per playing target, and
      // opening one is itself a peer connection. Rebuilding on that disposed
      // the `AmbientTargets` that had just connected, so every sweep tore
      // down the connections the previous sweep established.
      final statusNotifier = _FakeP2pStatusNotifier();

      final container = ProviderContainer(overrides: [
        p2pServiceProvider.overrideWithValue(_FakeP2pServiceWithHost()),
        p2pStatusNotifierProvider.overrideWith(() => statusNotifier),
        graphqlClientProvider.overrideWith(
          (ref) => stubClient(StubLink.responses([
            <String, dynamic>{'__typename': 'Query'},
          ])),
        ),
      ]);
      addTearDown(container.dispose);

      expect(container.read(ambientTargetsProvider), isNull);

      statusNotifier.publish('a' * 64);
      final before = container.read(ambientTargetsProvider);
      expect(before, isNotNull);

      statusNotifier.publishPeerConnected('a' * 64);

      expect(
        identical(container.read(ambientTargetsProvider), before),
        isTrue,
        reason: 'the same host and identity must keep the same ambient '
            'targets, or each sweep disposes its own connections',
      );
    });

    test('scans only the devices the server reports online, never itself',
        () async {
      // A device that is playing is talking to the server, so an offline one
      // cannot be what the banner is looking for, and each dial to it costs a
      // 10 second on-demand timeout on every 30 second scan.
      final statusNotifier = _FakeP2pStatusNotifier();

      final container = ProviderContainer(overrides: [
        p2pServiceProvider.overrideWithValue(_FakeP2pServiceWithHost()),
        p2pStatusNotifierProvider.overrideWith(() => statusNotifier),
        graphqlClientProvider.overrideWith(
          (ref) => stubClient(StubLink.responses([
            <String, dynamic>{
              '__typename': 'Query',
              'devices': [
                _device('this-device', 'a' * 64, online: true),
                _device('hall-screen', 'b' * 64, online: true),
                _device('attic-tablet', 'c' * 64, online: false),
              ],
            },
          ])),
        ),
      ]);
      addTearDown(container.dispose);

      expect(container.read(ambientTargetsProvider), isNull);

      statusNotifier.publish('a' * 64);
      final targets = container.read(ambientTargetsProvider);
      expect(targets, isNotNull);

      expect(await targets!.rosterSource(), ['b' * 64]);
    });

    test('the node address arriving does not rebuild ambient targets',
        () async {
      // Each rebuild is a new AmbientTargets and a fresh sweep, which is one
      // more OnlineDevices query on every launch.
      final statusNotifier = _FakeP2pStatusNotifier();

      final container = ProviderContainer(overrides: [
        p2pServiceProvider.overrideWithValue(_FakeP2pServiceWithHost()),
        p2pStatusNotifierProvider.overrideWith(() => statusNotifier),
        graphqlClientProvider.overrideWith(
          (ref) => stubClient(StubLink.responses([
            <String, dynamic>{'__typename': 'Query'},
          ])),
        ),
      ]);
      addTearDown(container.dispose);

      expect(container.read(ambientTargetsProvider), isNull);
      statusNotifier.publish('a' * 64);
      final before = container.read(ambientTargetsProvider);
      expect(before, isNotNull);

      statusNotifier.publishAddr('a' * 64, '{"id":"${'a' * 64}","addrs":[]}');

      expect(identical(container.read(ambientTargetsProvider), before), isTrue,
          reason: 'the provider never reads nodeAddr');
    });
  });
}
