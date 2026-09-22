import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/diagnostics/diagnostics_provider.dart';
import 'package:player/core/diagnostics/diagnostics_settings.dart';
import 'package:player/core/logging/log_uploader.dart';
import 'package:player/presentation/screens/settings/widgets/diagnostics_sharing_section.dart';

import '../../../../test_utils/memory_log_store.dart';
import '../../../../test_utils/toast_harness.dart';

class _FakeDiagnostics extends DiagnosticsController {
  _FakeDiagnostics(this.initial, {this.failSelect = false, this.onSend});

  final DiagnosticsState initial;
  final bool failSelect;
  final Future<String> Function(String? note)? onSend;
  final selected = <DiagnosticsChoice>[];

  @override
  Future<DiagnosticsState> build() async => initial;

  @override
  Future<void> select(DiagnosticsChoice choice) async {
    if (failSelect) throw Exception('keyring refused');
    selected.add(choice);
    state = AsyncData(DiagnosticsState(choice: choice));
  }

  @override
  Future<String> sendReport({String? note}) => onSend!(note);
}

/// A controller whose `build()` never completes, so the section stays in the
/// no-value state for the whole test.
class _PendingDiagnostics extends DiagnosticsController {
  final selected = <DiagnosticsChoice>[];

  @override
  Future<DiagnosticsState> build() => Completer<DiagnosticsState>().future;

  @override
  Future<void> select(DiagnosticsChoice choice) async {
    selected.add(choice);
  }
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

Future<_FakeDiagnostics> _pump(
  WidgetTester tester, {
  DiagnosticsState initial = DiagnosticsState.off,
  bool canShareLogs = true,
  bool failSelect = false,
  Future<String> Function(String? note)? onSend,
}) async {
  final fake =
      _FakeDiagnostics(initial, failSelect: failSelect, onSend: onSend);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        diagnosticsProvider.overrideWith(() => fake),
        logUploaderProvider
            .overrideWithValue(canShareLogs ? _uploader() : null),
      ],
      child: MaterialApp(
        builder: toastLayerBuilder,
        home: const Scaffold(
          body: SingleChildScrollView(child: DiagnosticsSharingSection()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return fake;
}

Finder _choice(DiagnosticsChoice choice) =>
    find.byKey(Key('diagnostics-level-${choice.keySuffix}'));

void main() {
  testWidgets('shows every choice with the stored one checked', (tester) async {
    await _pump(tester,
        initial: const DiagnosticsState(choice: DiagnosticsChoice.logsForever));

    for (final choice in DiagnosticsChoice.values) {
      expect(_choice(choice), findsOneWidget);
    }
    expect(
      find.descendant(
          of: _choice(DiagnosticsChoice.logsForever),
          matching: find.byIcon(Icons.check_circle)),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byKey(const Key('diagnostics-send-logs')), findsOneWidget);
  });

  testWidgets('a timed choice says when it ends', (tester) async {
    final until = DateTime(2026, 9, 29, 14).toUtc();
    await _pump(tester,
        initial: DiagnosticsState(
            choice: DiagnosticsChoice.logs24h, logsUntil: until));

    expect(find.text('Until Sep 29, 14:00'), findsOneWidget);
  });

  testWidgets('tapping a choice selects it', (tester) async {
    final fake = await _pump(tester);

    await tester.tap(_choice(DiagnosticsChoice.logs7d));
    await tester.pump();

    expect(fake.selected, [DiagnosticsChoice.logs7d]);
  });

  testWidgets('a choice that cannot be saved says so', (tester) async {
    await _pump(tester, failSelect: true);

    await tester.tap(_choice(DiagnosticsChoice.crashes));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Could not save that choice'), findsOneWidget);
  });

  testWidgets('without a log store only the crash choices remain',
      (tester) async {
    await _pump(tester, canShareLogs: false);

    expect(_choice(DiagnosticsChoice.off), findsOneWidget);
    expect(_choice(DiagnosticsChoice.crashes), findsOneWidget);
    expect(_choice(DiagnosticsChoice.logs24h), findsNothing);
    expect(_choice(DiagnosticsChoice.logsForever), findsNothing);
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

  testWidgets(
      'while the choice is still loading nothing is selected and taps do '
      'nothing', (tester) async {
    final pending = _PendingDiagnostics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          diagnosticsProvider.overrideWith(() => pending),
          logUploaderProvider.overrideWithValue(_uploader()),
        ],
        child: MaterialApp(
          builder: toastLayerBuilder,
          home: const Scaffold(
            body: SingleChildScrollView(child: DiagnosticsSharingSection()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byKey(const Key('diagnostics-send-logs')), findsNothing);

    await tester.tap(_choice(DiagnosticsChoice.crashes));
    await tester.pump();

    expect(pending.selected, isEmpty);
  });

  test('untilLabel', () {
    expect(untilLabel(null), isNull);
    expect(
        untilLabel(DateTime(2026, 1, 3, 9, 5).toUtc()), 'Until Jan 3, 09:05');
  });
}
