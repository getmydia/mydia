import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/presentation/widgets/connection_status_dot.dart';

class _FakeConnectionNotifier extends ConnectionNotifier {
  _FakeConnectionNotifier(this._state);

  final ConnectionState _state;

  @override
  ConnectionState build() => _state;
}

class _FakeP2pStatusNotifier extends P2pStatusNotifier {
  _FakeP2pStatusNotifier(this._status);

  final P2pStatus _status;

  @override
  P2pStatus build() => _status;
}

Future<void> _pump(
  WidgetTester tester, {
  required ConnectionType connection,
  required P2pStatus status,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(
          () => _FakeConnectionNotifier(ConnectionState(type: connection)),
        ),
        p2pStatusNotifierProvider.overrideWith(
          () => _FakeP2pStatusNotifier(status),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: ConnectionStatusDot())),
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
      connection: ConnectionType.direct,
      status: _idle,
    );

    expect(find.byTooltip('Connected to server'), findsOneWidget);
  });

  testWidgets('a relayed peer link says so in the tooltip', (tester) async {
    await _pump(
      tester,
      connection: ConnectionType.p2p,
      status: _idle.copyWith(peerConnectionType: P2pConnectionType.relay),
    );

    expect(find.byTooltip('Connected through a relay'), findsOneWidget);
  });

  testWidgets('reconnecting pulses rather than sitting still', (tester) async {
    await _pump(
      tester,
      connection: ConnectionType.p2p,
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
      connection: ConnectionType.p2p,
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
