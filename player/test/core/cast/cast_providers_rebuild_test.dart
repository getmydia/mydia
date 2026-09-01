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
}

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
  });
}
