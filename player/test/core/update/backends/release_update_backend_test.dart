import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/android_installer.dart';
import 'package:player/core/update/backends/release_update_backend.dart';
import 'package:player/core/update/platform_updater.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_service.dart';
import 'package:player/core/update/update_track.dart';
import 'package:player/domain/models/available_update.dart';

AppUpdate _update() => AppUpdate(
      version: '0.16.0',
      downloadUrl: 'https://example.invalid/player-linux-v0.16.0.tar.gz',
      releaseNotesUrl: 'https://example.invalid/releases/0.16.0',
      releaseTitle: 'Quieter scanning',
      publishedAt: DateTime.utc(2026, 9, 1),
    );

class _StubService implements UpdateService {
  _StubService(this._result);

  final AppUpdate? _result;
  int calls = 0;

  @override
  Future<AppUpdate?> checkForUpdate({
    required String currentVersion,
    required UpdateTrack track,
    bool force = false,
  }) async {
    calls++;
    return _result;
  }
}

class _RecordingUpdater extends PlatformUpdater {
  _RecordingUpdater({this.throws, this.handsOffUnconfirmed = false});

  final Object? throws;
  AvailableUpdate? applied;

  @override
  final bool handsOffUnconfirmed;

  @override
  bool get canUpdateInPlace => true;

  @override
  Future<void> applyUpdate(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    if (throws != null) throw throws!;
    applied = update;
    onProgress?.call(1.0);
  }
}

void main() {
  test('refresh publishes what the service found', () async {
    final backend = ReleaseUpdateBackend(
      updater: _RecordingUpdater(),
      currentVersion: '0.15.0',
      service: _StubService(_update()),
    );
    addTearDown(backend.dispose);

    final seen = <AvailableUpdate?>[];
    backend.availability.listen(seen.add);
    await backend.refresh(force: true);
    await Future<void>.delayed(Duration.zero);

    expect(seen.single, isA<AppUpdate>());
  });

  test('refresh publishes null when there is nothing', () async {
    final backend = ReleaseUpdateBackend(
      updater: _RecordingUpdater(),
      currentVersion: '0.15.0',
      service: _StubService(null),
    );
    addTearDown(backend.dispose);

    final seen = <AvailableUpdate?>[];
    backend.availability.listen(seen.add);
    await backend.refresh(force: true);
    await Future<void>.delayed(Duration.zero);

    expect(seen.single, isNull);
  });

  test('requestUpdate with nothing found reports up to date', () async {
    final backend = ReleaseUpdateBackend(
      updater: _RecordingUpdater(),
      currentVersion: '0.15.0',
      service: _StubService(null),
    );
    addTearDown(backend.dispose);

    expect(await backend.requestUpdate(), isA<AlreadyUpToDate>());
  });

  test('requestUpdate hands the found release to the updater', () async {
    final updater = _RecordingUpdater();
    final backend = ReleaseUpdateBackend(
      updater: updater,
      currentVersion: '0.15.0',
      service: _StubService(_update()),
    );
    addTearDown(backend.dispose);

    await backend.refresh(force: true);
    final outcome = await backend.requestUpdate();

    expect(outcome, isA<UpdateInstalled>());
    expect((updater.applied as AppUpdate).version, '0.16.0');
  });

  test('an updater that throws reports a failure rather than escaping',
      () async {
    final backend = ReleaseUpdateBackend(
      updater: _RecordingUpdater(throws: Exception('read-only file system')),
      currentVersion: '0.15.0',
      service: _StubService(_update()),
    );
    addTearDown(backend.dispose);

    await backend.refresh(force: true);
    final outcome = await backend.requestUpdate();

    expect(outcome, isA<UpdateFailed>());
    expect((outcome as UpdateFailed).message, contains('read-only'));
  });

  test('a refused install permission is unsupported, not a failure', () async {
    final backend = ReleaseUpdateBackend(
      updater: _RecordingUpdater(throws: InstallerPermissionDenied()),
      currentVersion: '0.15.0',
      service: _StubService(_update()),
    );
    addTearDown(backend.dispose);

    await backend.refresh(force: true);
    expect(await backend.requestUpdate(), isA<UpdateUnsupported>());
  });

  test('a missing installer is unsupported, not a failure', () async {
    final backend = ReleaseUpdateBackend(
      updater: _RecordingUpdater(throws: InstallerUnavailable()),
      currentVersion: '0.15.0',
      service: _StubService(_update()),
    );
    addTearDown(backend.dispose);

    await backend.refresh(force: true);
    expect(await backend.requestUpdate(), isA<UpdateUnsupported>());
  });

  test(
      'an updater that hands off unconfirmed reports deferred, not '
      'installed', () async {
    final updater = _RecordingUpdater(handsOffUnconfirmed: true);
    final backend = ReleaseUpdateBackend(
      updater: updater,
      currentVersion: '0.15.0',
      service: _StubService(_update()),
    );
    addTearDown(backend.dispose);

    await backend.refresh(force: true);
    final outcome = await backend.requestUpdate();

    // The updater has already handed the user off to Android's own
    // confirmation dialog by this point, so this must not claim the update
    // is installed before the user has answered it.
    expect(outcome, isA<UpdateDeferred>());
    expect(updater.applied, isNotNull);
  });

  test('the manual row checks only', () {
    final backend = ReleaseUpdateBackend(
      updater: _RecordingUpdater(),
      currentVersion: '0.15.0',
      service: _StubService(null),
    );
    addTearDown(backend.dispose);

    expect(backend.manualCheck, ManualCheckBehaviour.checksOnly);
  });
}
