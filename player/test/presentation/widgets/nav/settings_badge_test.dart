import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/app_update.dart';
import 'package:player/presentation/widgets/nav/nav_badges.dart';

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

class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier(this._state);
  final UpdateState _state;

  @override
  UpdateState build() => _state;

  @override
  Future<void> applyUpdate() async {}
}

const _idle = P2pStatus(
  isInitialized: true,
  isRelayConnected: false,
  connectedPeersCount: 0,
);

AppUpdate _update() => AppUpdate(
      version: '0.15.0',
      downloadUrl: 'https://example.invalid/player-linux-v0.15.0.tar.gz',
      releaseNotesUrl: 'https://example.invalid/releases/0.15.0',
      releaseTitle: 'Faster library scans',
      publishedAt: DateTime.utc(2026, 8, 1),
    );

Future<void> _pump(
  WidgetTester tester, {
  required UpdateState update,
  ConnectionType connection = ConnectionType.direct,
  P2pStatus status = _idle,
  bool supported = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(
          () => _FakeConnectionNotifier(ConnectionState(type: connection)),
        ),
        p2pStatusNotifierProvider
            .overrideWith(() => _FakeP2pStatusNotifier(status)),
        updateProvider.overrideWith(() => _FakeUpdateNotifier(update)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: SettingsBadge(supportedOverride: supported)),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The circle itself.
///
/// `find.byType(Container)` alone can match more than the dot once Tooltip
/// wraps it, so match on the one Container carrying a circular BoxDecoration.
Container _dotOf(WidgetTester tester) => tester.widget<Container>(
      find.descendant(
        of: find.byType(SettingsBadge),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.decoration is BoxDecoration &&
              (widget.decoration! as BoxDecoration).shape == BoxShape.circle,
        ),
      ),
    );

void main() {
  testWidgets('with no update it is a plain 10px dot', (tester) async {
    await _pump(tester, update: const UpdateState(currentVersion: '0.14.2'));

    expect(find.byIcon(Icons.arrow_upward), findsNothing);
    expect(_dotOf(tester).constraints?.maxWidth, 10);
  });

  testWidgets('a pending update changes the shape, not the colour',
      (tester) async {
    await _pump(
      tester,
      update: UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
      connection: ConnectionType.p2p,
      status: _idle.copyWith(peerConnectionType: P2pConnectionType.relay),
    );

    // Shape says "update", colour still says "relayed". Two signals, two
    // channels, one mark.
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    final decoration = _dotOf(tester).decoration! as BoxDecoration;
    expect(decoration.color, AppColors.warning);
  });

  testWidgets('the tooltip carries both facts', (tester) async {
    await _pump(
      tester,
      update: UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
    );

    expect(
      find.byTooltip('Update available - Connected to server'),
      findsOneWidget,
    );
  });

  testWidgets('a platform that cannot self-update shows a plain dot',
      (tester) async {
    await _pump(
      tester,
      update: UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
      supported: false,
    );

    expect(find.byIcon(Icons.arrow_upward), findsNothing);
    expect(find.byTooltip('Connected to server'), findsOneWidget);
  });
}
