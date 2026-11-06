import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/android_installer.dart';
import 'package:player/core/update/backends/release_update_backend.dart';
import 'package:player/core/update/platform_updater.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_service.dart';
import 'package:player/core/update/update_track.dart';
import 'package:player/domain/models/available_update.dart';

AppUpdate _update({String version = '0.16.0'}) => AppUpdate(
      version: version,
      downloadUrl: 'https://example.invalid/player-linux-v$version.tar.gz',
      releaseNotesUrl: 'https://example.invalid/releases/$version',
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
  _RecordingUpdater({
    this.throws,
    this.handsOffUnconfirmed = false,
    this.installsWithoutAsking = false,
  });

  final Exception? throws;
  AvailableUpdate? applied;

  @override
  final bool handsOffUnconfirmed;

  @override
  final bool installsWithoutAsking;

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
    expect((outcome as UpdateFailed).problem.text, contains('read-only'));
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

  group('an updater that installs without asking (Android)', () {
    test('makes the manual row install in one press', () {
      final backend = ReleaseUpdateBackend(
        updater: _RecordingUpdater(installsWithoutAsking: true),
        currentVersion: '0.15.0',
        service: _StubService(null),
      );
      addTearDown(backend.dispose);

      expect(backend.manualCheck, ManualCheckBehaviour.installsWithoutAsking);
    });

    test('checks first when nothing is known yet, then installs', () async {
      final updater = _RecordingUpdater(installsWithoutAsking: true);
      final service = _StubService(_update());
      final backend = ReleaseUpdateBackend(
        updater: updater,
        currentVersion: '0.15.0',
        service: service,
      );
      addTearDown(backend.dispose);

      final seen = <AvailableUpdate?>[];
      backend.availability.listen(seen.add);
      final outcome = await backend.requestUpdate();
      await Future<void>.delayed(Duration.zero);

      expect(service.calls, 1);
      // Published, so the card can show the version it is downloading.
      expect(seen.single, isA<AppUpdate>());
      expect(outcome, isA<UpdateInstalled>());
      expect((updater.applied as AppUpdate).version, '0.16.0');
    });

    test('reports up to date when the check finds nothing', () async {
      final updater = _RecordingUpdater(installsWithoutAsking: true);
      final backend = ReleaseUpdateBackend(
        updater: updater,
        currentVersion: '0.15.0',
        service: _StubService(null),
      );
      addTearDown(backend.dispose);

      expect(await backend.requestUpdate(), isA<AlreadyUpToDate>());
      expect(updater.applied, isNull);
    });

    test('a failed check is a failure, not an escape', () async {
      final backend = ReleaseUpdateBackend(
        updater: _RecordingUpdater(installsWithoutAsking: true),
        currentVersion: '0.15.0',
        service: _ThrowingService(),
      );
      addTearDown(backend.dispose);

      expect(await backend.requestUpdate(), isA<UpdateFailed>());
    });

    test('checks again and installs a newer release than the one it held',
        () async {
      final updater = _RecordingUpdater(installsWithoutAsking: true);
      final service = _SequenceService([_update(), _update(version: '0.17.0')]);
      final backend = ReleaseUpdateBackend(
        updater: updater,
        currentVersion: '0.15.0',
        service: service,
      );
      addTearDown(backend.dispose);

      await backend.refresh(force: true);
      await backend.requestUpdate();

      expect((updater.applied as AppUpdate).version, '0.17.0');
      // Forced, so UpdateService's rate limit cannot answer the press with
      // the startup check's result.
      expect(service.forced, [true, true]);
    });

    test('installs the release it held when the fresh check fails', () async {
      final updater = _RecordingUpdater(installsWithoutAsking: true);
      final backend = ReleaseUpdateBackend(
        updater: updater,
        currentVersion: '0.15.0',
        service: _SequenceService([_update(), Exception('feed unreachable')]),
      );
      addTearDown(backend.dispose);

      await backend.refresh(force: true);
      final outcome = await backend.requestUpdate();

      expect(outcome, isA<UpdateInstalled>());
      expect((updater.applied as AppUpdate).version, '0.16.0');
    });
  });

  test('a checks-only updater never checks from requestUpdate', () async {
    final service = _StubService(_update());
    final backend = ReleaseUpdateBackend(
      updater: _RecordingUpdater(),
      currentVersion: '0.15.0',
      service: service,
    );
    addTearDown(backend.dispose);

    expect(await backend.requestUpdate(), isA<AlreadyUpToDate>());
    expect(service.calls, 0);
  });
}

/// Answers each check with the next entry: an update, null, or an
/// exception to throw.
class _SequenceService implements UpdateService {
  _SequenceService(this._answers);

  final List<Object?> _answers;
  int _next = 0;

  /// The force argument of each check, in order.
  final forced = <bool>[];

  @override
  Future<AppUpdate?> checkForUpdate({
    required String currentVersion,
    required UpdateTrack track,
    bool force = false,
  }) async {
    forced.add(force);
    final answer = _answers[_next++];
    if (answer is Exception) throw answer;
    return answer as AppUpdate?;
  }
}

class _ThrowingService implements UpdateService {
  @override
  Future<AppUpdate?> checkForUpdate({
    required String currentVersion,
    required UpdateTrack track,
    bool force = false,
  }) async =>
      throw Exception('feed unreachable');
}
