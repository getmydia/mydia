import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/auth/auth_storage.dart';
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

/// Delays reads and/or writes, so a test can control the relative order in
/// which build()'s load() and a select()'s save() settle.
///
/// [delay] is mutable rather than final: a test can speed up (or slow down)
/// calls made after a certain point without retroactively affecting ones
/// already in flight, since `Future.delayed` captures the duration when it
/// starts, not by reference to this field.
class _DelayedAuthStorage implements AuthStorage {
  _DelayedAuthStorage(
    this._inner,
    this.delay, {
    this.delayReads = false,
    this.delayWrites = true,
  });

  final AuthStorage _inner;
  final bool delayReads;
  final bool delayWrites;
  Duration delay;

  @override
  bool get degraded => _inner.degraded;

  @override
  Future<String?> read(String key) async {
    if (delayReads) await Future<void>.delayed(delay);
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (delayWrites) await Future<void>.delayed(delay);
    await _inner.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    if (delayWrites) await Future<void>.delayed(delay);
    await _inner.delete(key);
  }

  @override
  Future<void> deleteAll() => _inner.deleteAll();
}

class _Harness {
  _Harness({
    DateTime Function()? now,
    bool available = true,
    Duration? slowSave,
    Duration? slowLoad,
  }) : now = now ?? (() => DateTime.utc(2026, 9, 22, 12)) {
    if (slowSave != null) {
      delayedStorage =
          _DelayedAuthStorage(storage, slowSave, delayWrites: true);
    } else if (slowLoad != null) {
      delayedStorage = _DelayedAuthStorage(storage, slowLoad,
          delayReads: true, delayWrites: false);
    }
    settings = DiagnosticsSettings(
      storage: delayedStorage ?? storage,
      now: this.now,
    );
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
  _DelayedAuthStorage? delayedStorage;
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

  test(
      'a selection made while the provider is still building computes '
      'wasSharing from the value build() was loading, not from the '
      'still-loading state', () {
    fakeAsync((async) {
      final start = DateTime.utc(2026, 9, 22, 12);
      final h = _Harness(
        now: () => start.add(async.elapsed),
        slowLoad: const Duration(seconds: 1),
      );
      addTearDown(h.dispose);

      // Already sharing logs, with a cursor already advanced past what is
      // on disk. Writes are not delayed by slowLoad, so this settles
      // immediately.
      h.settings
          .save(const DiagnosticsState(choice: DiagnosticsChoice.logsForever));
      async.flushMicrotasks();
      h.store.savedCursor = const LogCursor('mem', 5);

      // Trigger build(), which is now stuck on the delayed read (so `state`
      // reads AsyncLoading, not yet the value build() is loading), then
      // issue a selection before it settles.
      h.container.read(diagnosticsProvider);
      h.controller.select(DiagnosticsChoice.logs24h);
      async.flushMicrotasks();

      // Let the delayed read, and everything after it, settle.
      async.elapse(const Duration(seconds: 2));

      expect(h.container.read(diagnosticsProvider).value?.choice,
          DiagnosticsChoice.logs24h);
      // wasSharing must reflect build()'s loaded value (already sharing),
      // not the AsyncLoading state select() saw when it started, so the
      // cursor already on disk is kept rather than reset to the end.
      expect(h.store.savedCursor, const LogCursor('mem', 5));
      expect(h.uploader.isActive, isTrue);
    });
  });

  test(
      'an expiry that fires while a user selection is in flight does not '
      'undo that selection', () {
    fakeAsync((async) {
      final start = DateTime.utc(2026, 9, 22, 12);
      final h = _Harness(
        now: () => start.add(async.elapsed),
        slowSave: const Duration(seconds: 3),
      );
      addTearDown(h.dispose);

      h.container.read(diagnosticsProvider);
      async.flushMicrotasks();

      h.controller.select(DiagnosticsChoice.logs24h);
      // Two delayed storage writes (choice, then the window's end) to let
      // settle before reading the armed end time.
      async.elapse(const Duration(seconds: 10));
      expect(h.uploader.isActive, isTrue);
      final until = h.container.read(diagnosticsProvider).value!.logsUntil!;

      // Start a new, still-slow selection one second before the original
      // timer is due, so that timer fires while this selection's save is
      // still in flight.
      async.elapse(until.difference(h.now()) - const Duration(seconds: 1));
      h.controller.select(DiagnosticsChoice.logsForever);
      async.elapse(const Duration(seconds: 12));

      expect(h.container.read(diagnosticsProvider).value?.choice,
          DiagnosticsChoice.logsForever);
      expect(h.storage.contents[DiagnosticsSettings.choiceKey], 'logs_forever');
      expect(h.uploader.isActive, isTrue);
    });
  });

  test(
      'two selections issued back to back apply in order, with the last '
      'one winning', () {
    fakeAsync((async) {
      final start = DateTime.utc(2026, 9, 22, 12);
      final h = _Harness(
        now: () => start.add(async.elapsed),
        slowSave: const Duration(seconds: 2),
      );
      addTearDown(h.dispose);

      h.container.read(diagnosticsProvider);
      async.flushMicrotasks();

      // The first selection's save is slow (2s per write); let it reach its
      // first delayed write, then speed up later calls before issuing the
      // second selection, so a lack of serialization would let the second
      // one finish first and the (still in-flight) first one clobber it
      // afterward.
      h.controller.select(DiagnosticsChoice.logs24h);
      async.flushMicrotasks();
      h.delayedStorage!.delay = Duration.zero;
      h.controller.select(DiagnosticsChoice.logsForever);
      async.elapse(const Duration(seconds: 3));

      expect(h.container.read(diagnosticsProvider).value?.choice,
          DiagnosticsChoice.logsForever);
      expect(h.storage.contents[DiagnosticsSettings.choiceKey], 'logs_forever');
      expect(h.uploader.isActive, isTrue);
    });
  });
}
