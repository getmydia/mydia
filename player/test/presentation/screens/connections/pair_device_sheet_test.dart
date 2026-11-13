import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_group_roster.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/connections/pair_device_sheet.dart';
import 'package:player/presentation/widgets/toast/toaster.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../test_utils/toast_harness.dart';
import 'fake_peer_sync_service.dart';

Widget _wrap(
    FakePeerSyncService service, PeerSyncStore store, PairSheetMode mode) {
  final roster = PeerGroupRoster(
    store: store,
    localNodeId: () => service.localNodeId,
    isPeerConnected: (_) => true,
  );
  return ProviderScope(
    overrides: [
      peerSyncServiceProvider.overrideWithValue(service),
      peerSyncStoreProvider.overrideWithValue(store),
      peerGroupRosterProvider.overrideWithValue(roster),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open-sheet'),
            onPressed: () => showPairDeviceSheet(context, mode: mode),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<(FakePeerSyncService, PeerSyncStore)> _open(
  WidgetTester tester,
  PairSheetMode mode,
) async {
  final store = InMemoryPeerSyncStore();
  final service = FakePeerSyncService(store: store);
  await tester.pumpWidget(_wrap(service, store, mode));
  await tester.tap(find.byKey(const Key('open-sheet')));
  await tester.pumpAndSettle();
  return (service, store);
}

void main() {
  testWidgets('show mode starts an offer on open and shows code and QR',
      (tester) async {
    final (service, _) = await _open(tester, PairSheetMode.show);

    expect(service.startOfferCount, 1);
    expect(find.byKey(const Key('pair-active-code')), findsOneWidget);
    expect(find.text('ABC-123'), findsOneWidget);
    expect(find.byKey(const Key('pair-active-qr')), findsOneWidget);
    final qr = tester.widget<PairingQrCode>(
      find.byKey(const Key('pair-active-qr-image')),
    );
    expect(qr.data, service.activeOffer!.qrJson);
    expect(
      find.descendant(
        of: find.byKey(const Key('pair-active-qr-image')),
        matching: find.byType(QrImageView),
      ),
      findsOneWidget,
    );
    expect(jsonDecode(qr.data), containsPair('claim_code', 'ABC123'));
    expect(find.byKey(const Key('pair-code-input')), findsNothing);
  });

  testWidgets('cancel button closes the sheet and cancels the offer',
      (tester) async {
    final (service, _) = await _open(tester, PairSheetMode.show);

    // The sheet scrolls once its header is in: bring the button up first.
    await tester
        .ensureVisible(find.byKey(const Key('pair-cancel-offer-button')));
    await tester.tap(find.byKey(const Key('pair-cancel-offer-button')));
    await tester.pumpAndSettle();

    expect(find.byType(PairDeviceSheet), findsNothing);
    expect(service.cancelOfferCount, 1);
  });

  testWidgets('closing with an active offer cancels it', (tester) async {
    final (service, _) = await _open(tester, PairSheetMode.show);
    expect(service.activeOffer, isNotNull);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byType(PairDeviceSheet), findsNothing);
    expect(service.cancelOfferCount, 1);
  });

  /// Opens the show sheet with its offer still pending, then closes it.
  Future<(FakePeerSyncService, Completer<void>)> openPendingThenClose(
      WidgetTester tester) async {
    final store = InMemoryPeerSyncStore();
    final service = FakePeerSyncService(store: store);
    final gate = Completer<void>();
    service.offerGate = gate;
    await tester.pumpWidget(_wrap(service, store, PairSheetMode.show));
    await tester.tap(find.byKey(const Key('open-sheet')));
    // The pending offer's spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(service.startOfferCount, 1);
    expect(service.activeOffer, isNull);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(PairDeviceSheet), findsNothing);
    return (service, gate);
  }

  testWidgets('an offer that arrives after the sheet closed is cancelled',
      (tester) async {
    final (service, gate) = await openPendingThenClose(tester);

    gate.complete();
    await tester.pumpAndSettle();

    expect(service.cancelOfferCount, 1);
    expect(service.activeOffer, isNull);
  });

  testWidgets('a late offer never cancels a newer one', (tester) async {
    final (service, gate) = await openPendingThenClose(tester);

    service.supersedeOffer = true;
    gate.complete();
    await tester.pumpAndSettle();

    expect(service.cancelOfferCount, 0);
    expect(service.activeOffer?.code, 'XYZ789');
  });

  testWidgets('enter mode shows a focused code input and no offer',
      (tester) async {
    final (service, _) = await _open(tester, PairSheetMode.enter);

    expect(service.startOfferCount, 0);
    expect(find.byKey(const Key('pair-code-input')), findsOneWidget);
    expect(find.byKey(const Key('pair-submit-code-button')), findsOneWidget);
    expect(find.byKey(const Key('pair-active-code')), findsNothing);
    final field = tester.widget<TextField>(
      find.byKey(const Key('pair-code-input')),
    );
    expect(field.autofocus, isTrue);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(service.cancelOfferCount, 0);
  });

  testWidgets('each mode names the sheet and tells the other side what to do',
      (tester) async {
    await _open(tester, PairSheetMode.show);
    expect(find.byKey(const Key('pair-sheet-title')), findsOneWidget);
    expect(find.text('Sync another Mydia Player'), findsOneWidget);
    expect(
      find.text('Open Mydia Player on your other device, go to Servers & '
          'devices, and choose Enter code from other device.'),
      findsOneWidget,
    );

    await tester
        .ensureVisible(find.byKey(const Key('pair-cancel-offer-button')));
    await tester.tap(find.byKey(const Key('pair-cancel-offer-button')));
    await tester.pumpAndSettle();

    await _open(tester, PairSheetMode.enter);
    expect(find.text('Sync another Mydia Player'), findsOneWidget);
    expect(
      find.text('On your other device, open Servers & devices and choose '
          'Show code on this device. Then enter that code here.'),
      findsOneWidget,
    );
  });

  testWidgets('hides the scan button where the scanner is unsupported',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _open(tester, PairSheetMode.enter);
      expect(find.byKey(const Key('pair-scan-qr-button')), findsNothing);
      expect(find.byKey(const Key('pair-code-input')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('shows the scan button where the scanner is supported',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await _open(tester, PairSheetMode.enter);
      expect(find.byKey(const Key('pair-scan-qr-button')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('submitting a code pairs, toasts once and closes the sheet',
      (tester) async {
    final (service, _) = await _open(tester, PairSheetMode.enter);

    await tester.enterText(find.byKey(const Key('pair-code-input')), 'abc-123');
    await tester.tap(find.byKey(const Key('pair-submit-code-button')));
    await tester.pumpAndSettle();

    expect(service.pairWithCodeCalls, ['ABC123']);
    expect(find.text('Synced with Living Room TV'), findsOneWidget);
    expect(find.byType(PairDeviceSheet), findsNothing);
  });

  testWidgets('a joined code with no member yet toasts a plain success',
      (tester) async {
    final store = InMemoryPeerSyncStore();
    final service = FakePeerSyncService(store: store)..skipJoinedMember = true;
    await tester.pumpWidget(_wrap(service, store, PairSheetMode.enter));
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('pair-code-input')), 'ABC123');
    await tester.tap(find.byKey(const Key('pair-submit-code-button')));
    await tester.pumpAndSettle();

    expect(find.text('Device synced'), findsOneWidget);
    expect(find.byType(PairDeviceSheet), findsNothing);
  });

  testWidgets('a join that also fires onPeerPaired toasts once',
      (tester) async {
    final store = InMemoryPeerSyncStore();
    final service = FakePeerSyncService(store: store)..emitPairedOnJoin = true;
    await tester.pumpWidget(_wrap(service, store, PairSheetMode.enter));
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();
    // A second toast replaces the first, so count what was shown.
    final toasts = Toaster.maybeControllerOf(
        tester.element(find.byType(PairDeviceSheet)))!;
    final shown = <int>{};
    toasts.addListener(() {
      final id = toasts.current?.id;
      if (id != null) shown.add(id);
    });

    await tester.enterText(find.byKey(const Key('pair-code-input')), 'ABC123');
    await tester.tap(find.byKey(const Key('pair-submit-code-button')));
    await tester.pumpAndSettle();

    expect(find.text('Synced with Living Room TV'), findsOneWidget);
    expect(shown, hasLength(1));
    expect(find.byType(PairDeviceSheet), findsNothing);
  });

  testWidgets('the host sheet closes on onPeerPaired', (tester) async {
    final (service, store) = await _open(tester, PairSheetMode.show);
    expect(find.byType(PairDeviceSheet), findsOneWidget);

    await service.hostPaired(PeerMember(
      nodeId: 'peer-device-qr',
      deviceName: 'Bedroom TV',
      platform: 'ios',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await tester.pumpAndSettle();

    expect(find.text('Synced with Bedroom TV'), findsOneWidget);
    expect(find.byType(PairDeviceSheet), findsNothing);
    expect(store.member('peer-device-qr'), isNotNull);
  });

  testWidgets('a failed offer shows the failure banner', (tester) async {
    final store = InMemoryPeerSyncStore();
    final service = FakePeerSyncService(store: store)..failOffer = true;
    await tester.pumpWidget(_wrap(service, store, PairSheetMode.show));
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pair-failure-banner')), findsOneWidget);
    expect(find.byKey(const Key('pair-active-code')), findsNothing);
  });

  testWidgets('a failed code shows the failure banner and keeps the sheet',
      (tester) async {
    final store = InMemoryPeerSyncStore();
    final service = FakePeerSyncService(store: store)..failPairing = true;
    await tester.pumpWidget(_wrap(service, store, PairSheetMode.enter));
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('pair-code-input')), 'ZZZ999');
    await tester.tap(find.byKey(const Key('pair-submit-code-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pair-failure-banner')), findsOneWidget);
    expect(find.byType(PairDeviceSheet), findsOneWidget);
  });

  testWidgets('wide windows open the sheet as a dialog', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _open(tester, PairSheetMode.enter);

    expect(find.byType(PairDeviceSheet), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('narrow windows open the sheet as a bottom sheet',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _open(tester, PairSheetMode.enter);

    expect(find.byType(BottomSheet), findsOneWidget);
  });
}
