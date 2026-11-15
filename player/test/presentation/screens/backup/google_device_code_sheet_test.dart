import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/cloud/google_auth.dart';
import 'package:player/core/backup/cloud/google_oauth_flows.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/backup/google_device_code_sheet.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../test_utils/toast_harness.dart';

/// Opens the sheet over [flows], one stream per attempt; the result lands
/// in [result].
Future<List<bool?>> _open(
    WidgetTester tester, List<StreamController<DeviceCodeState>> flows) async {
  tester.view.physicalSize = const Size(1200, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final result = <bool?>[];
  var attempt = 0;
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: toastLayerBuilder,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: const Key('open'),
          onPressed: () async => result.add(await showGoogleDeviceCodeSheet(
              context, () => flows[attempt++].stream)),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pump();
  return result;
}

const _scopeMissingText = 'Mydia needs permission to store its backup in '
    'your Google Drive. Sign in again and allow it.';

DeviceCodePending _pending(String code) => DeviceCodePending(
      userCode: code,
      verificationUrl: Uri.parse('https://www.google.com/device'),
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
    );

void main() {
  testWidgets('device_code_sheet_shows_code_and_qr_and_expiry', (tester) async {
    final first = StreamController<DeviceCodeState>();
    final second = StreamController<DeviceCodeState>();
    final result = await _open(tester, [first, second]);

    expect(find.text('Sign in to Google'), findsOneWidget);
    first.add(_pending('ABCD-EFGH'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'On your phone, open https://www.google.com/device and enter this code:'),
        findsOneWidget);
    expect(find.text('ABCD-EFGH'), findsOneWidget);
    final qr = tester
        .widget<QrImageView>(find.byKey(const Key('google-device-code-qr')));
    expect(qr, isNotNull);

    first.add(const DeviceCodeExpired());
    await first.close();
    await tester.pumpAndSettle();
    expect(find.text('The code expired. Try again.'), findsOneWidget);
    expect(find.text('ABCD-EFGH'), findsNothing);

    await tester.tap(find.byKey(const Key('google-device-code-retry')));
    await tester.pump();
    second.add(_pending('WXYZ-1234'));
    await tester.pumpAndSettle();
    expect(find.text('WXYZ-1234'), findsOneWidget);

    second.add(const DeviceCodeDone('ana@example.com'));
    await second.close();
    await tester.pumpAndSettle();
    expect(result, [true]);
    expect(find.text('Sign in to Google'), findsNothing);
  });

  testWidgets('a declined sign-in closes the sheet, signed out',
      (tester) async {
    final flow = StreamController<DeviceCodeState>();
    final result = await _open(tester, [flow]);
    flow.add(_pending('ABCD-EFGH'));
    await tester.pumpAndSettle();

    flow.add(const DeviceCodeDenied());
    await flow.close();
    await tester.pumpAndSettle();

    expect(result, [false]);
  });

  testWidgets('a grant without Drive access shows the scope message',
      (tester) async {
    final flow = StreamController<DeviceCodeState>();
    final result = await _open(tester, [flow]);
    flow.add(_pending('ABCD-EFGH'));
    await tester.pumpAndSettle();

    flow.addError(const BackupRelayException(BackupRelayError.signedOut,
        code: googleScopeMissingCode));
    await flow.close();
    await tester.pumpAndSettle();

    expect(result, [false]);
    expect(find.text(_scopeMissingText), findsOneWidget);
  });

  testWidgets('signInToGoogle shows the scope message for a Drive-less grant',
      (tester) async {
    bool? signedIn;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('sign-in'),
            onPressed: () async => signedIn = await signInToGoogle(
              context,
              GoogleSignInMethod(
                currentEmail: () async => null,
                signIn: () async => throw const BackupRelayException(
                    BackupRelayError.signedOut,
                    code: googleScopeMissingCode),
              ),
            ),
            child: const Text('sign in'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('sign-in')));
    await tester.pumpAndSettle();

    expect(signedIn, isFalse);
    expect(find.text(_scopeMissingText), findsOneWidget);
  });

  testWidgets('cancel closes the sheet and stops listening', (tester) async {
    final flow = StreamController<DeviceCodeState>();
    final result = await _open(tester, [flow]);
    flow.add(_pending('ABCD-EFGH'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('google-device-code-cancel')));
    await tester.pumpAndSettle();

    expect(result, [false]);
    expect(flow.hasListener, isFalse);
    // Nobody listens any more, so the close never reports done.
    unawaited(flow.close());
  });

  testWidgets('cancel_closes_once_ignoring_subsequent_stream_events',
      (tester) async {
    // Broadcast stream allows pushing events synchronously/right after cancel
    // even if a native stream does not drop events immediately.
    final flow = StreamController<DeviceCodeState>.broadcast();
    final result = await _open(tester, [flow]);
    flow.add(_pending('ABCD-EFGH'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('google-device-code-cancel')));
    // Emit both done and an error immediately before the frame settles.
    flow.add(const DeviceCodeDone('ana@example.com'));
    flow.addError(StateError('late'));
    await tester.pumpAndSettle();

    expect(result, [false]);
    expect(find.byKey(const Key('open')), findsOneWidget);
    await flow.close();
  });
}
