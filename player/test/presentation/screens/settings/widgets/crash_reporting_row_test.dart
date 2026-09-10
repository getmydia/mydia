import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/crash_reporting/crash_report.dart';
import 'package:player/core/crash_reporting/crash_reporter.dart';
import 'package:player/core/crash_reporting/crash_reporter_provider.dart';
import 'package:player/presentation/screens/settings/widgets/crash_reporting_row.dart';
import 'package:player/presentation/screens/settings/widgets/settings_row.dart';

CrashReporter _reporter({
  bool stored = false,
  Future<void> Function(bool enabled)? save,
}) =>
    CrashReporter(
      client: MockClient((_) async => http.Response('{}', 201)),
      endpoint: Uri.parse('https://relay.test/crashes/report'),
      loadConsent: () async => stored,
      saveConsent: save ?? (_) async {},
      loadAppContext: () async => const CrashAppContext(
        version: '0.52.1',
        buildNumber: '5201',
        platform: 'linux',
        osVersion: 'Ubuntu 24.04',
        environment: 'prod',
      ),
    );

void main() {
  Future<void> pump(WidgetTester tester, CrashReporter reporter) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [crashReporterProvider.overrideWithValue(reporter)],
        child: const MaterialApp(home: Scaffold(body: CrashReportingRow())),
      ),
    );
    await tester.pumpAndSettle();
  }

  SettingsRow row(WidgetTester tester) => tester
      .widget<SettingsRow>(find.byKey(const Key('crash-reporting-switch')));

  testWidgets('starts off when the user has not opted in', (tester) async {
    await pump(tester, _reporter());

    expect(row(tester).toggleValue, isFalse);
  });

  testWidgets('reflects an existing opt-in', (tester) async {
    await pump(tester, _reporter(stored: true));

    expect(row(tester).toggleValue, isTrue);
  });

  testWidgets('turning it on stores the choice and the reporter applies it',
      (tester) async {
    final stored = <bool>[];
    final reporter = _reporter(save: (enabled) async => stored.add(enabled));
    await pump(tester, reporter);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(stored, [true]);
    expect(row(tester).toggleValue, isTrue);
    expect(await reporter.isEnabled(), isTrue);
  });

  testWidgets('reverts when the choice cannot be stored', (tester) async {
    // Gated so the optimistic value is observable before the write fails,
    // as in beta_channel_row_test.dart.
    final gate = Completer<void>();
    await pump(
      tester,
      _reporter(
        save: (_) async {
          await gate.future;
          throw Exception('keyring refused');
        },
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(row(tester).toggleValue, isTrue,
        reason: 'the switch should move optimistically');

    gate.complete();
    await tester.pumpAndSettle();
    expect(row(tester).toggleValue, isFalse,
        reason: 'a write that did not land must revert');
  });

  testWidgets('uses the server wording and says what is sent', (tester) async {
    await pump(tester, _reporter());

    expect(find.text('Share crashes with developers'), findsOneWidget);
    expect(
      find.text(
        'Sends error details, app version and platform to the Mydia '
        'developers when the app hits an error.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('uses no em dashes in its copy', (tester) async {
    await pump(tester, _reporter());

    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data ?? '', isNot(contains('—')));
    }
  });
}
