import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/diagnostics/diagnostics_provider.dart';
import 'package:player/core/diagnostics/diagnostics_settings.dart';
import 'package:player/core/logging/log_uploader.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/settings/widgets/diagnostics_sharing_section.dart';

import '../../../../test_utils/memory_log_store.dart';
import '../../../../test_utils/toast_harness.dart';

class _FakeDiagnostics extends DiagnosticsController {
  _FakeDiagnostics(this.initial, {this.failWrites = false, this.onSend});

  final DiagnosticsState initial;
  final bool failWrites;
  final Future<String> Function(String? note)? onSend;
  final calls = <String>[];

  @override
  Future<DiagnosticsState> build() async => initial;

  @override
  Future<void> setCrashes(bool on) async {
    if (failWrites) throw Exception('keyring refused');
    calls.add('crashes:$on');
    state = AsyncData(state.requireValue.copyWith(crashes: on));
  }

  @override
  Future<void> setLogs(bool on) async {
    if (failWrites) throw Exception('keyring refused');
    calls.add('logs:$on');
    state = AsyncData(state.requireValue.copyWith(logs: on));
  }

  @override
  Future<String> sendReport({String? note}) => onSend!(note);
}

/// A controller whose `build()` never completes, so the section stays in the
/// no-value state for the whole test.
class _PendingDiagnostics extends DiagnosticsController {
  @override
  Future<DiagnosticsState> build() => Completer<DiagnosticsState>().future;
}

LogUploader _uploader() => LogUploader(
      client: MockClient((_) async => http.Response('', 204)),
      endpoint: Uri.parse('https://relay.test/player-logs'),
      store: MemoryLogStore(),
      sessionId: 's',
      loadMeta: () async => const LogUploadMeta(
        deviceId: 'd',
        deviceName: 'Work MacBook',
        platform: 'linux',
        osVersion: 'Fedora Linux 42',
        appVersion: '0.15.0',
        build: '150',
      ),
      compress: (bytes) => bytes,
    );

Future<void> _pumpWith(
  WidgetTester tester,
  DiagnosticsController controller, {
  bool canShareLogs = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        diagnosticsProvider.overrideWith(() => controller),
        logUploaderProvider
            .overrideWithValue(canShareLogs ? _uploader() : null),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: toastLayerBuilder,
        home: Scaffold(
          body: SingleChildScrollView(child: DiagnosticsSharingSection()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<_FakeDiagnostics> _pump(
  WidgetTester tester, {
  DiagnosticsState initial = DiagnosticsState.off,
  bool canShareLogs = true,
  bool failWrites = false,
  Future<String> Function(String? note)? onSend,
}) async {
  final fake =
      _FakeDiagnostics(initial, failWrites: failWrites, onSend: onSend);
  await _pumpWith(tester, fake, canShareLogs: canShareLogs);
  return fake;
}

const _crashes = Key('diagnostics-crashes');
const _logs = Key('diagnostics-logs');

Finder _switchOf(Key row) =>
    find.descendant(of: find.byKey(row), matching: find.byType(Switch));

Switch _switch(WidgetTester tester, Key row) =>
    tester.widget<Switch>(_switchOf(row));

void main() {
  testWidgets('each switch shows its stored value', (tester) async {
    await _pump(tester,
        initial: const DiagnosticsState(crashes: true, logs: false));

    expect(_switch(tester, _crashes).value, isTrue);
    expect(_switch(tester, _logs).value, isFalse);
    expect(find.byKey(const Key('diagnostics-send-logs')), findsOneWidget);
  });

  testWidgets('flipping a switch calls its own setter', (tester) async {
    final fake = await _pump(tester);

    await tester.tap(_switchOf(_logs));
    await tester.pump();
    await tester.tap(_switchOf(_crashes));
    await tester.pump();

    expect(fake.calls, ['logs:true', 'crashes:true']);
    expect(_switch(tester, _logs).value, isTrue);
    expect(_switch(tester, _crashes).value, isTrue);
  });

  testWidgets('a change that cannot be saved says so', (tester) async {
    await _pump(tester, failWrites: true);

    await tester.tap(_switchOf(_crashes));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Could not save that choice'), findsOneWidget);
    expect(_switch(tester, _crashes).value, isFalse);
  });

  testWidgets('without a log store only crash reports remain', (tester) async {
    await _pump(tester, canShareLogs: false);

    expect(find.byKey(_crashes), findsOneWidget);
    expect(find.byKey(_logs), findsNothing);
    expect(find.byKey(const Key('diagnostics-send-logs')), findsNothing);
  });

  testWidgets('while loading both switches are off and disabled',
      (tester) async {
    await _pumpWith(tester, _PendingDiagnostics());

    for (final row in [_crashes, _logs]) {
      expect(_switch(tester, row).value, isFalse);
      expect(_switch(tester, row).onChanged, isNull);
    }
    expect(find.byKey(const Key('diagnostics-send-logs')), findsNothing);
  });

  testWidgets('Send logs now shows the code', (tester) async {
    String? sentNote;
    await _pump(tester, onSend: (note) async {
      sentNote = note;
      return 'LOG-7K2QX9';
    });

    await tester.tap(find.byKey(const Key('diagnostics-send-logs')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('diagnostics-send-logs-note')), 'Audio drifts');
    await tester.tap(find.byKey(const Key('diagnostics-send-logs-confirm')));
    await tester.pumpAndSettle();

    expect(sentNote, 'Audio drifts');
    expect(find.byKey(const Key('diagnostics-report-code')), findsOneWidget);
    expect(find.text('LOG-7K2QX9'), findsOneWidget);
    expect(find.byKey(const Key('diagnostics-report-copy')), findsOneWidget);
  });

  testWidgets('a failed send offers a retry', (tester) async {
    var attempts = 0;
    await _pump(tester, onSend: (_) async {
      attempts++;
      if (attempts == 1) {
        throw const LogUploadException('The relay did not accept these logs.');
      }
      return 'LOG-7K2QX9';
    });

    await tester.tap(find.byKey(const Key('diagnostics-send-logs')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-send-logs-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('The relay did not accept these logs.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('diagnostics-report-retry')));
    await tester.pumpAndSettle();

    expect(find.text('LOG-7K2QX9'), findsOneWidget);
  });

  testWidgets('a back press cannot drop an in-flight upload', (tester) async {
    final completer = Completer<String>();
    await _pump(tester, onSend: (_) => completer.future);

    await tester.tap(find.byKey(const Key('diagnostics-send-logs')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-send-logs-confirm')));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(find.text('Send logs'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete('LOG-7K2QX9');
    await tester.pumpAndSettle();

    expect(find.text('LOG-7K2QX9'), findsOneWidget);
  });
}
