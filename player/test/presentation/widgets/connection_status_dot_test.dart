import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/connection_status_dot.dart';

import '../../core/sources/mydia/fake_mydia_transport.dart';
import '../../test_utils/mydia_test_source.dart';

const _p2p =
    MydiaCredentials(instanceId: 'i', accessToken: 'a', nodeAddr: 'node-1');
const _direct = MydiaCredentials(
    instanceId: 'i', accessToken: 'a', serverUrl: 'http://box.test');

class _FakeP2pStatusNotifier extends P2pStatusNotifier {
  _FakeP2pStatusNotifier(this._status);

  final P2pStatus _status;

  @override
  P2pStatus build() => _status;
}

Future<void> _pump(
  WidgetTester tester, {
  required MydiaCredentials connection,
  required P2pStatus status,
}) async {
  final source = testMydiaSourceOver(FakeMydiaTransport(), creds: connection);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mediaSourceProvider(testMydiaSourceId).overrideWithValue(source),
        p2pStatusNotifierProvider.overrideWith(
          () => _FakeP2pStatusNotifier(status),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: ConnectionStatusDot(
              location: '/s/${testMydiaSourceId.value}/home',
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

const _idle = P2pStatus(
  isInitialized: true,
  isRelayConnected: false,
  connectedPeersCount: 0,
);

void main() {
  testWidgets('a direct connection is described without p2p jargon',
      (tester) async {
    await _pump(
      tester,
      connection: _direct,
      status: _idle,
    );

    expect(find.byTooltip('Connected to server'), findsOneWidget);
  });

  testWidgets('a relayed peer link says so in the tooltip', (tester) async {
    await _pump(
      tester,
      connection: _p2p,
      status: _idle.copyWith(peerConnectionType: P2pConnectionType.relay),
    );

    expect(find.byTooltip('Connected through a relay'), findsOneWidget);
  });

  testWidgets('reconnecting pulses rather than sitting still', (tester) async {
    await _pump(
      tester,
      connection: _p2p,
      status: _idle.copyWith(peerConnectionType: P2pConnectionType.none),
    );

    expect(find.byTooltip('Reconnecting'), findsOneWidget);
    // Existing shell animation uses AnimatedBuilder + Opacity driven by an
    // AnimationController (not FadeTransition). Tooltip also builds an
    // AnimatedBuilder over a ValueNotifier, so match on the controller.
    expect(_pulsingAnimation, findsOneWidget);
  });

  testWidgets('connecting before initialization does not pulse',
      (tester) async {
    await _pump(
      tester,
      connection: _p2p,
      status: const P2pStatus(
        isInitialized: false,
        isRelayConnected: false,
        connectedPeersCount: 0,
      ),
    );

    expect(find.byTooltip('Connecting'), findsOneWidget);
    expect(_pulsingAnimation, findsNothing);
  });
}

final Finder _pulsingAnimation = find.byWidgetPredicate(
  (widget) =>
      widget is AnimatedBuilder && widget.listenable is AnimationController,
);
