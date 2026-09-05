import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/backends/flatpak_update_backend.dart';
import 'package:player/core/update/flatpak_portal.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/domain/models/available_update.dart';

const _notes = 'https://github.com/getmydia/mydia/releases/latest';

class _FakePortal implements FlatpakPortal {
  _FakePortal({this.progress = const [], this.failStartWith});

  final List<FlatpakProgress> progress;
  final Object? failStartWith;

  final available = StreamController<FlatpakCommits>.broadcast();
  Object? updateError;
  bool restarted = false;
  bool closed = false;
  int updateCalls = 0;
  int startCalls = 0;

  @override
  Stream<FlatpakCommits> get updatesAvailable => available.stream;

  @override
  Future<void> startMonitoring() async {
    startCalls++;
    if (failStartWith != null) throw failStartWith!;
  }

  @override
  Stream<FlatpakProgress> update() {
    updateCalls++;
    if (updateError != null) return Stream.error(updateError!);
    return Stream.fromIterable(progress);
  }

  @override
  Future<void> restartIntoLatest() async => restarted = true;

  @override
  Future<void> close() async {
    closed = true;
    await available.close();
  }
}

void main() {
  test('a newer remote commit surfaces a version-less update', () async {
    final portal = _FakePortal();
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    final seen = <AvailableUpdate?>[];
    backend.availability.listen(seen.add);
    portal.available.add(const FlatpakCommits(
      running: 'aaa',
      local: 'aaa',
      remote: 'bbb',
    ));
    await Future<void>.delayed(Duration.zero);

    final update = seen.single as FlatpakRemoteUpdate;
    expect(update.version, isNull);
    expect(update.installedAwaitingRestart, isFalse);
    expect(update.releaseNotesUrl, _notes);
  });

  test('a commit already deployed underneath us only asks for a restart',
      () async {
    final portal = _FakePortal();
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    final seen = <AvailableUpdate?>[];
    backend.availability.listen(seen.add);
    portal.available.add(const FlatpakCommits(
      running: 'aaa',
      local: 'bbb',
      remote: 'bbb',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(
        (seen.single as FlatpakRemoteUpdate).installedAwaitingRestart, isTrue);
  });

  test(
      'a newer remote landing while a previous install awaits restart '
      'downloads first', () async {
    // awaitingRestart and updateReady are independent booleans over the same
    // three commits, not exclusive states: both are true here. Downloading
    // first gets the user to the newest build with one restart instead of
    // two, so the card must not claim a restart is all that is needed, and
    // requestUpdate must not short-circuit past the transaction.
    final portal = _FakePortal(progress: const [
      FlatpakProgress(progress: 100, status: FlatpakProgressStatus.done),
    ]);
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    final seen = <AvailableUpdate?>[];
    backend.availability.listen(seen.add);
    portal.available.add(const FlatpakCommits(
      running: 'aaa',
      local: 'bbb',
      remote: 'ccc',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(
        (seen.single as FlatpakRemoteUpdate).installedAwaitingRestart, isFalse);

    final outcome = await backend.requestUpdate();

    expect(portal.updateCalls, 1);
    expect(outcome, isA<UpdateInstalled>());
  });

  test('nothing newer publishes null', () async {
    final portal = _FakePortal();
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    final seen = <AvailableUpdate?>[];
    backend.availability.listen(seen.add);
    portal.available.add(const FlatpakCommits(
      running: 'aaa',
      local: 'aaa',
      remote: 'aaa',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(seen.single, isNull);
  });

  test('an empty transaction reports up to date', () async {
    final portal = _FakePortal(progress: const [
      FlatpakProgress(progress: 0, status: FlatpakProgressStatus.empty),
    ]);
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    expect(await backend.requestUpdate(), isA<AlreadyUpToDate>());
  });

  test('a completed transaction reports installed and needing a restart',
      () async {
    final portal = _FakePortal(progress: const [
      FlatpakProgress(progress: 50, status: FlatpakProgressStatus.running),
      FlatpakProgress(progress: 100, status: FlatpakProgressStatus.done),
    ]);
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    final progress = <double>[];
    final outcome = await backend.requestUpdate(onProgress: progress.add);

    expect(outcome, isA<UpdateInstalled>());
    expect((outcome as UpdateInstalled).restartRequired, isTrue);
    expect(progress, [0.5, 1.0]);
  });

  test('a failed transaction carries the portal message through', () async {
    final portal = _FakePortal(progress: const [
      FlatpakProgress(
        progress: 0,
        status: FlatpakProgressStatus.failed,
        errorMessage: 'While pulling: connection reset',
      ),
    ]);
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    final outcome = await backend.requestUpdate();

    expect(outcome, isA<UpdateFailed>());
    expect((outcome as UpdateFailed).message, contains('connection reset'));
  });

  test('a stream that ends without a terminal status is not success', () async {
    // Reporting this as done would send the user to restart into a build
    // that was never installed.
    final portal = _FakePortal(progress: const [
      FlatpakProgress(progress: 50, status: FlatpakProgressStatus.running),
    ]);
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    final outcome = await backend.requestUpdate();

    expect(outcome, isA<UpdateFailed>());
    expect((outcome as UpdateFailed).message, contains('without reporting'));
  });

  test('a refusal arriving on the Progress signal also reports unsupported',
      () async {
    // The portal can reject on permissions asynchronously rather than as a
    // synchronous NotSupported, so the error name has to be classified here
    // too. Reporting this one as a generic failure would tell the user to
    // retry something that will never succeed.
    final portal = _FakePortal(progress: const [
      FlatpakProgress(
        progress: 0,
        status: FlatpakProgressStatus.failed,
        errorName: 'org.freedesktop.DBus.Error.NotSupported',
        errorMessage: 'Update requires new permissions',
      ),
    ]);
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    final outcome = await backend.requestUpdate();

    expect(outcome, isA<UpdateUnsupported>());
    expect((outcome as UpdateUnsupported).reason, contains('permissions'));
  });

  test('a refused update reports unsupported, not failed', () async {
    final portal = _FakePortal();
    portal.updateError = FlatpakUpdateNotPermitted();
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    final outcome = await backend.requestUpdate();

    expect(outcome, isA<UpdateUnsupported>());
    expect((outcome as UpdateUnsupported).reason, contains('permissions'));
  });

  test('an update already installed skips the transaction entirely', () async {
    final portal = _FakePortal();
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    portal.available.add(const FlatpakCommits(
      running: 'aaa',
      local: 'bbb',
      remote: 'bbb',
    ));
    await Future<void>.delayed(Duration.zero);

    final outcome = await backend.requestUpdate();

    expect(portal.updateCalls, 0);
    expect(outcome, isA<UpdateInstalled>());
    expect((outcome as UpdateInstalled).restartRequired, isTrue);
  });

  test('two overlapping presses only open one transaction', () async {
    // Progress is broadcast per monitor, not per call. Two open transactions
    // against the same monitor would each observe the other's signals, so
    // the second caller must ride the first call's transaction rather than
    // starting its own.
    final portal = _FakePortal(progress: const [
      FlatpakProgress(progress: 100, status: FlatpakProgressStatus.done),
    ]);
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    final first = backend.requestUpdate();
    final second = backend.requestUpdate();
    final results = await Future.wait([first, second]);

    expect(portal.updateCalls, 1);
    expect(results[0], isA<UpdateInstalled>());
    expect(results[1], same(results[0]));
  });

  test('restart asks the portal for the newest commit', () async {
    final portal = _FakePortal();
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    await backend.restart();

    expect(portal.restarted, isTrue);
  });

  test('a portal that refuses to start reports no in-place update', () async {
    final portal = _FakePortal(failStartWith: Exception('no portal'));
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    expect(backend.canUpdateInPlace, isFalse);
  });

  test('a dropped connection rebuilds the monitor for the next press',
      () async {
    final portal = _FakePortal();
    portal.updateError = Exception('connection reset by peer');
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    expect(portal.startCalls, 1);
    final outcome = await backend.requestUpdate();

    expect(outcome, isA<UpdateFailed>());
    // The next press must not be doomed by the first one.
    expect(portal.startCalls, 2);
    expect(backend.canUpdateInPlace, isTrue);
  });

  test('the row still checks and installs when the portal never started',
      () async {
    final portal = _FakePortal(failStartWith: Exception('no portal'));
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    // The row has to route somewhere that can explain itself, so it keeps
    // pointing at requestUpdate.
    expect(backend.manualCheck, ManualCheckBehaviour.checksAndInstalls);
    final outcome = await backend.requestUpdate();
    expect(outcome, isA<UpdateFailed>());
    expect((outcome as UpdateFailed).message, contains('software centre'));
  });

  test('refresh is a no-op, because the portal owns the polling', () async {
    final portal = _FakePortal();
    final backend =
        FlatpakUpdateBackend(portal: portal, releaseNotesUrl: _notes);
    await backend.start();
    addTearDown(backend.dispose);

    await backend.refresh(force: true);

    expect(portal.updateCalls, 0);
  });
}
