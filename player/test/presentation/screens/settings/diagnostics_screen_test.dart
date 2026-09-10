import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/player/fullscreen/fullscreen_failure.dart';
import 'package:player/core/player/fullscreen/fullscreen_mode.dart';
import 'package:player/core/player/fullscreen/fullscreen_report.dart';
import 'package:player/core/player/fullscreen/fullscreen_report_signal.dart';
import 'package:player/presentation/screens/settings/diagnostics_screen.dart';

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
  ConnectionType connection = ConnectionType.p2p,
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
      child: const MaterialApp(home: DiagnosticsScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows the relay url when there is one', (tester) async {
    await _pump(
      tester,
      status: const P2pStatus(
        isInitialized: true,
        isRelayConnected: true,
        connectedPeersCount: 2,
        relayUrl: 'https://relay.mydia.dev',
        peerConnectionType: P2pConnectionType.relay,
      ),
    );

    expect(find.text('https://relay.mydia.dev'), findsOneWidget);
    expect(find.text('Connected through a relay'), findsOneWidget);
  });

  testWidgets('omits the relay row entirely when there is no url',
      (tester) async {
    await _pump(
      tester,
      status: const P2pStatus(
        isInitialized: true,
        isRelayConnected: false,
        connectedPeersCount: 0,
        peerConnectionType: P2pConnectionType.direct,
      ),
    );

    expect(find.text('Relay server'), findsNothing);
  });

  testWidgets('reads zero peers as words rather than a bare zero',
      (tester) async {
    await _pump(
      tester,
      status: const P2pStatus(
        isInitialized: true,
        isRelayConnected: false,
        connectedPeersCount: 0,
        peerConnectionType: P2pConnectionType.direct,
      ),
    );

    expect(find.text('None connected'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('shows the node address when the peer link is up',
      (tester) async {
    await _pump(
      tester,
      status: const P2pStatus(
        isInitialized: true,
        isRelayConnected: true,
        connectedPeersCount: 1,
        nodeAddr: 'k51qzi5uqu5dabc',
        peerConnectionType: P2pConnectionType.direct,
      ),
    );

    expect(find.text('k51qzi5uqu5dabc'), findsOneWidget);
  });

  testWidgets('copy diagnostics puts the details on the clipboard',
      (tester) async {
    final written = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          written.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await _pump(
      tester,
      status: const P2pStatus(
        isInitialized: true,
        isRelayConnected: true,
        connectedPeersCount: 2,
        relayUrl: 'https://relay.mydia.dev',
        peerConnectionType: P2pConnectionType.relay,
      ),
    );

    await tester.tap(find.byKey(const Key('copy-diagnostics')));
    await tester.pump();

    expect(written, hasLength(1));
    expect(written.single, contains('https://relay.mydia.dev'));
    expect(written.single, contains('Connected through a relay'));
  });

  // The Playback section is the only way to ask an iPhone what its fullscreen
  // module decided. Everything it reports used to be a `debugPrint`, which on
  // that device needs a Mac with Safari Web Inspector attached.
  group('playback section', () {
    tearDown(() => fullscreenReportSignal.value = null);

    testWidgets('says so when nothing has played this session', (tester) async {
      fullscreenReportSignal.value = null;

      await _pump(tester, status: const P2pStatus.initial());

      expect(find.text('Playback'), findsOneWidget);
      expect(find.text('Nothing played yet this session'), findsOneWidget);
    });

    testWidgets('shows the route, readiness and what refused', (tester) async {
      fullscreenReportSignal.value = const FullscreenReport(
        mode: FullscreenMode.unsupported,
        ready: false,
        demoted: true,
        documentFullscreenEnabled: true,
        videoElementFullscreenSupported: false,
        lastFailure: FullscreenFailure(
          FullscreenFailureCause.documentRequestRejected,
          detail: 'NotAllowedError',
        ),
      );

      await _pump(tester, status: const P2pStatus.initial());

      expect(find.text('Route'), findsOneWidget);
      expect(find.text('unsupported'), findsOneWidget);
      expect(find.text('Fell back'), findsOneWidget);
      expect(find.text('Last failure'), findsOneWidget);
    });

    testWidgets('the copy button carries every row the screen shows',
        (tester) async {
      final written = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            written.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      const report = FullscreenReport(
        mode: FullscreenMode.nativeVideoElement,
        ready: true,
        mediaElementBound: true,
        demoted: true,
        documentFullscreenEnabled: true,
        videoElementFullscreenSupported: true,
      );
      fullscreenReportSignal.value = report;

      // The Playback section pushes the button past the fold on the default
      // 800x600 surface, and the `ListView` never builds what it cannot show.
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pump(tester, status: const P2pStatus.initial());
      await tester.tap(find.byKey(const Key('copy-diagnostics')));
      await tester.pump();

      expect(written, hasLength(1));
      for (final (label, value) in report.rows) {
        expect(written.single, contains('$label: $value'));
      }
    });
  });
}
