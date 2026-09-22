import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/crash_reporting/crash_report.dart';
import 'package:player/core/crash_reporting/crash_reporter.dart';
import 'package:player/core/crash_reporting/crash_reporter_provider.dart';
import 'package:player/core/diagnostics/diagnostics_provider.dart';
import 'package:player/core/diagnostics/diagnostics_settings.dart';
import 'package:player/core/logging/log_record.dart';
import 'package:player/core/logging/log_store.dart';
import 'package:player/core/logging/log_uploader.dart';

import '../../test_utils/memory_log_store.dart';
import '../../test_utils/mock_auth_storage.dart';

const _context = CrashAppContext(
  version: '0.15.0',
  buildNumber: '150',
  platform: 'linux',
  osVersion: 'Fedora Linux 42',
  environment: 'prod',
);

const _meta = LogUploadMeta(
  deviceId: 'd-1',
  deviceName: 'Work MacBook',
  platform: 'linux',
  osVersion: 'Fedora Linux 42',
  appVersion: '0.15.0',
  build: '150',
);

class _Harness {
  _Harness({DateTime Function()? now, bool available = true})
      : now = now ?? (() => DateTime.utc(2026, 9, 22, 12)) {
    settings = DiagnosticsSettings(storage: storage, now: this.now);
    reporter = CrashReporter(
      client: MockClient((_) async => http.Response('{}', 201)),
      endpoint: Uri.parse('https://relay.test/crashes/report'),
      loadConsent: () async => false,
      loadAppContext: () async => _context,
      isAvailable: available,
    );
    uploader = LogUploader(
      client: MockClient((_) async => http.Response('', 204)),
      endpoint: Uri.parse('https://relay.test/player-logs'),
      store: store,
      sessionId: 'sess0001',
      loadMeta: () async => _meta,
      compress: (bytes) => bytes,
      now: this.now,
    );
    container = ProviderContainer(overrides: [
      crashReporterProvider.overrideWithValue(reporter),
      diagnosticsSettingsProvider.overrideWithValue(settings),
      logUploaderProvider.overrideWithValue(uploader),
      diagnosticsClockProvider.overrideWithValue(this.now),
    ]);
  }

  final DateTime Function() now;
  final storage = MockAuthStorage();
  final store = MemoryLogStore();
  late final DiagnosticsSettings settings;
  late final CrashReporter reporter;
  late final LogUploader uploader;
  late final ProviderContainer container;

  DiagnosticsController get controller =>
      container.read(diagnosticsProvider.notifier);

  Future<DiagnosticsState> get loaded =>
      container.read(diagnosticsProvider.future);

  void writeRecord() => store.add(LogRecord(
        time: now(),
        level: LogLevel.info,
        tag: 'Test',
        message: 'line',
        sessionId: 'sess0001',
      ));

  Future<void> dispose() async {
    await uploader.deactivate();
    container.dispose();
  }
}

void main() {
  test('with the inert reporter, resolves to off without reading storage',
      () async {
    final h = _Harness(available: false);
    addTearDown(h.dispose);
    await h.storage.write(DiagnosticsSettings.choiceKey, 'logs_forever');

    expect(await h.loaded, DiagnosticsState.off);
    expect(h.uploader.isActive, isFalse);
  });

  test('loads the stored choice and applies it', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.settings
        .save(const DiagnosticsState(choice: DiagnosticsChoice.logsForever));

    expect((await h.loaded).choice, DiagnosticsChoice.logsForever);
    expect(await h.reporter.isEnabled(), isTrue);
    expect(h.uploader.isActive, isTrue);
  });

  test('select stores the choice, tells the reporter and starts sharing',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.loaded;

    await h.controller.select(DiagnosticsChoice.logs24h);

    final stored = await h.settings.load();
    expect(stored.choice, DiagnosticsChoice.logs24h);
    expect(stored.logsUntil, h.now().add(const Duration(hours: 24)));
    expect(await h.reporter.isEnabled(), isTrue);
    expect(h.uploader.isActive, isTrue);
    expect(h.container.read(diagnosticsProvider).value?.choice,
        DiagnosticsChoice.logs24h);
  });

  test('off stops crash reports and log sharing', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.loaded;
    await h.controller.select(DiagnosticsChoice.logsForever);

    await h.controller.select(DiagnosticsChoice.off);

    expect(await h.reporter.isEnabled(), isFalse);
    expect(h.uploader.isActive, isFalse);
  });

  test('turning sharing on skips logs already on disk', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.writeRecord();
    h.writeRecord();
    await h.loaded;

    await h.controller.select(DiagnosticsChoice.logsForever);

    expect(h.store.savedCursor, const LogCursor('mem', 2));
  });

  test('changing the window while sharing keeps the cursor', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.settings
        .save(const DiagnosticsState(choice: DiagnosticsChoice.logsForever));
    h.store.savedCursor = const LogCursor('mem', 0);
    h.writeRecord();
    await h.loaded;

    await h.controller.select(DiagnosticsChoice.logs7d);

    expect(h.store.savedCursor, const LogCursor('mem', 0));
  });

  test('a choice that cannot be stored changes nothing', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.loaded;
    h.storage.failAllWrites = true;

    await expectLater(
        h.controller.select(DiagnosticsChoice.logsForever), throwsA(anything));

    expect(h.container.read(diagnosticsProvider).value, DiagnosticsState.off);
    expect(h.uploader.isActive, isFalse);
  });

  test('a timed choice falls back to crashes when it ends', () {
    fakeAsync((async) {
      final start = DateTime.utc(2026, 9, 22, 12);
      final h = _Harness(now: () => start.add(async.elapsed));
      h.container.read(diagnosticsProvider);
      async.flushMicrotasks();

      h.controller.select(DiagnosticsChoice.logs24h);
      async.flushMicrotasks();
      expect(h.uploader.isActive, isTrue);

      async.elapse(const Duration(hours: 24, seconds: 1));

      expect(h.container.read(diagnosticsProvider).value?.choice,
          DiagnosticsChoice.crashes);
      expect(h.uploader.isActive, isFalse);
      h.container.dispose();
    });
  });
}
