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

const _both = DiagnosticsState(crashes: true, logs: true);
const _logsOnly = DiagnosticsState(crashes: false, logs: true);

/// Delays reads and/or writes, so a test can control the relative order in
/// which build()'s load() and a setter's save() settle.
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
    bool available = true,
    Duration? slowSave,
    Duration? slowLoad,
  }) {
    if (slowSave != null) {
      delayedStorage =
          _DelayedAuthStorage(storage, slowSave, delayWrites: true);
    } else if (slowLoad != null) {
      delayedStorage = _DelayedAuthStorage(storage, slowLoad,
          delayReads: true, delayWrites: false);
    }
    settings = DiagnosticsSettings(storage: delayedStorage ?? storage);
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
      now: now,
    );
    container = ProviderContainer(overrides: [
      crashReporterProvider.overrideWithValue(reporter),
      diagnosticsSettingsProvider.overrideWithValue(settings),
      logUploaderProvider.overrideWithValue(uploader),
    ]);
  }

  static DateTime now() => DateTime.utc(2026, 9, 22, 12);

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

  DiagnosticsState? get current => container.read(diagnosticsProvider).value;

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
    await h.settings.save(_both);

    expect(await h.loaded, DiagnosticsState.off);
    expect(h.uploader.isActive, isFalse);
  });

  test('loads the stored switches and applies them', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.settings.save(_both);

    expect(await h.loaded, _both);
    expect(await h.reporter.isEnabled(), isTrue);
    expect(h.uploader.isActive, isTrue);
  });

  test('setCrashes stores it and tells the reporter, leaving logs alone',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.loaded;

    await h.controller.setCrashes(true);

    const expected = DiagnosticsState(crashes: true, logs: false);
    expect(await h.settings.load(), expected);
    expect(h.current, expected);
    expect(await h.reporter.isEnabled(), isTrue);
    expect(h.uploader.isActive, isFalse);

    await h.controller.setCrashes(false);

    expect(await h.reporter.isEnabled(), isFalse);
  });

  test('setLogs starts and stops sharing without changing crash consent',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.loaded;

    await h.controller.setLogs(true);

    expect(await h.settings.load(), _logsOnly);
    expect(h.uploader.isActive, isTrue);
    expect(await h.reporter.isEnabled(), isFalse);

    await h.controller.setLogs(false);

    expect(h.current, DiagnosticsState.off);
    expect(h.uploader.isActive, isFalse);
  });

  test('turning logs on skips logs already on disk', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.writeRecord();
    h.writeRecord();
    await h.loaded;

    await h.controller.setLogs(true);

    expect(h.store.savedCursor, const LogCursor('mem', 2));
  });

  test('changing crash reports while sharing logs keeps the cursor', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.settings.save(_logsOnly);
    h.store.savedCursor = const LogCursor('mem', 0);
    h.writeRecord();
    await h.loaded;

    await h.controller.setCrashes(true);

    expect(h.store.savedCursor, const LogCursor('mem', 0));
  });

  test('a change that cannot be stored changes nothing', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.loaded;
    h.storage.failAllWrites = true;

    await expectLater(h.controller.setLogs(true), throwsA(anything));

    expect(h.current, DiagnosticsState.off);
    expect(h.uploader.isActive, isFalse);
  });

  test(
      'a change made while the provider is still building layers on the '
      'value build() was loading', () {
    fakeAsync((async) {
      final h = _Harness(slowLoad: const Duration(seconds: 1));
      addTearDown(h.dispose);

      // Already sharing logs, with a cursor already advanced past what is
      // on disk. Writes are not delayed by slowLoad, so this settles
      // immediately.
      h.settings.save(_logsOnly);
      async.flushMicrotasks();
      h.store.savedCursor = const LogCursor('mem', 5);

      // Trigger build(), which is now stuck on the delayed read (so `state`
      // reads AsyncLoading), then change a switch before it settles.
      h.container.read(diagnosticsProvider);
      h.controller.setCrashes(true);
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 2));

      // Built on the loaded value, so logs stay on and the cursor already on
      // disk is kept rather than reset to the end.
      expect(h.current, _both);
      expect(h.store.savedCursor, const LogCursor('mem', 5));
      expect(h.uploader.isActive, isTrue);
    });
  });

  test('two changes issued back to back both land, in order', () {
    fakeAsync((async) {
      final h = _Harness(slowSave: const Duration(seconds: 2));
      addTearDown(h.dispose);

      h.container.read(diagnosticsProvider);
      async.flushMicrotasks();

      // The first change's save is slow (2s per write); let it reach its
      // first delayed write, then speed up later calls before issuing the
      // second, so a lack of serialization would let the second compute its
      // state from the stale one and clobber the first.
      h.controller.setLogs(true);
      async.flushMicrotasks();
      h.delayedStorage!.delay = Duration.zero;
      h.controller.setCrashes(true);
      async.elapse(const Duration(seconds: 5));

      expect(h.current, _both);
      expect(h.storage.contents[DiagnosticsSettings.crashesKey], 'true');
      expect(h.storage.contents[DiagnosticsSettings.logsKey], 'true');
      expect(h.uploader.isActive, isTrue);
    });
  });
}
