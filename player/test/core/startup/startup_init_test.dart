import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/startup/startup_init.dart';
import 'package:player/core/startup/startup_timeline.dart';

/// A `FileSystemException` on a `.lock` path, which is what
/// `isLockContentionError` (`startup_lock_native.dart`) recognizes regardless
/// of platform: it flags either a `.lock`-suffixed path or this platform's
/// "already locked" OS error code, and a bare `Exception` subclass matches
/// neither. Mirrors `startup_lock_test.dart`'s reproduction of the two-
/// instance failure.
class _LockError extends FileSystemException {
  _LockError()
      : super(
          'lock failed: Resource temporarily unavailable, errno = 11',
          '/tmp/mydia-test/download_tasks.lock',
        );
}

StartupSteps _steps({
  Future<void> Function()? rustInit,

  /// True for a build with no Rust bridge to load (web without p2p), which
  /// `runStartup` sees as `StartupSteps.rustInit == null`. Plain `rustInit:
  /// null` can't express this: the default below only applies when the
  /// caller passes nothing at all.
  bool noRustBridge = false,
  Future<void> Function()? hiveCache,
  Future<FetchLog> Function()? fetchLog,
  Future<void> Function()? downloadDb,
  Future<SidebarLayoutStore> Function()? sidebar,
  List<String>? started,
}) {
  Future<void> Function() track(String name, [Future<void> Function()? body]) =>
      () async {
        started?.add(name);
        await (body?.call() ?? Future<void>.value());
      };
  return StartupSteps(
    rustInit: noRustBridge ? null : (rustInit ?? track('rust')),
    inputCapabilities: track('input'),
    hiveCache: hiveCache ?? track('hive'),
    fetchLog: fetchLog ?? () async => InMemoryFetchLog(),
    downloadDb: downloadDb ?? track('downloads'),
    sidebarLayoutStore: sidebar ?? () async => InMemorySidebarLayoutStore(),
    connection: () async => null,
  );
}

void main() {
  test('independent steps start before a slow Rust init finishes', () async {
    final rust = Completer<void>();
    final started = <String>[];
    final outcome = runStartup(
      _steps(rustInit: () => rust.future, started: started),
      timeline: StartupTimeline('t'),
    );
    await pumpEventQueue();
    expect(started, containsAll(['input', 'hive', 'downloads']));
    rust.complete();
    expect(await outcome, isA<StartupReady>());
  });

  test('the sidebar store is read only after the Hive group', () async {
    final hive = Completer<void>();
    var sidebarRead = false;
    final outcome = runStartup(
      _steps(
        hiveCache: () => hive.future,
        sidebar: () async {
          sidebarRead = true;
          return InMemorySidebarLayoutStore();
        },
      ),
      timeline: StartupTimeline('t'),
    );
    await pumpEventQueue();
    expect(sidebarRead, isFalse);
    hive.complete();
    await outcome;
    expect(sidebarRead, isTrue);
  });

  test('a Rust init failure wins', () async {
    final outcome = await runStartup(
      _steps(
        rustInit: () async => throw StateError('no bridge'),
        downloadDb: () async => throw _LockError(),
      ),
      timeline: StartupTimeline('t'),
    );
    expect(outcome, isA<StartupRustFailed>());
  });

  test('lock contention on the download db is already-running', () async {
    final outcome = await runStartup(
      _steps(downloadDb: () async => throw _LockError()),
      timeline: StartupTimeline('t'),
    );
    expect(outcome, isA<StartupAlreadyRunning>());
  });

  test('a non-lock fetch log failure falls back to in-memory', () async {
    final outcome = await runStartup(
      _steps(fetchLog: () async => throw StateError('corrupt box')),
      timeline: StartupTimeline('t'),
    );
    expect(outcome, isA<StartupReady>());
    expect((outcome as StartupReady).fetchLog, isA<InMemoryFetchLog>());
  });

  test('records the step marks', () async {
    final timeline = StartupTimeline('t');
    await runStartup(_steps(), timeline: timeline);
    expect(
      timeline.marks.keys,
      containsAll([
        'rust_init',
        'input_caps',
        'hive',
        'download_db',
        'connection',
        'sidebar',
        'init_done'
      ]),
    );
  });

  test('a null Rust init still records rust_init and succeeds', () async {
    final timeline = StartupTimeline('t');
    final outcome = await runStartup(
      _steps(noRustBridge: true),
      timeline: timeline,
    );
    expect(timeline.marks.keys, contains('rust_init'));
    expect(outcome, isA<StartupReady>());
  });
}
