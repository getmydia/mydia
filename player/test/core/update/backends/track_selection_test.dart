import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_storage.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/update/backends/flatpak_update_backend.dart';
import 'package:player/core/update/backends/release_update_backend.dart';
import 'package:player/core/update/backends/sparkle_update_backend.dart';
import 'package:player/core/update/flatpak_portal.dart';
import 'package:player/core/update/platform_updater.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_track.dart';
import 'package:player/core/update/update_track_store.dart';
import 'package:player/domain/models/available_update.dart';

class _NoopUpdater extends PlatformUpdater {
  @override
  bool get canUpdateInPlace => true;

  @override
  Future<void> applyUpdate(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {}
}

/// An in-memory [AuthStorage], so a test can read back what a
/// [UpdateTrackStore] actually persisted rather than trusting the backend's
/// own field.
class _FakeAuthStorage implements AuthStorage {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<void> deleteAll() async => _values.clear();

  @override
  bool get degraded => false;
}

void main() {
  test('the release backend applies a switch itself', () async {
    final backend = ReleaseUpdateBackend(
      updater: _NoopUpdater(),
      currentVersion: '0.15.0',
    );
    addTearDown(backend.dispose);

    expect(backend.currentTrack, UpdateTrack.stable);
    expect(
        await backend.selectTrack(UpdateTrack.beta), isA<TrackSwitchApplied>());
    expect(backend.currentTrack, UpdateTrack.beta);
  });

  test('a track outside the platform set is refused, not switched', () async {
    final backend = ReleaseUpdateBackend(
      updater: _NoopUpdater(),
      currentVersion: '0.15.0',
      availableTracks: const {UpdateTrack.stable, UpdateTrack.beta},
    );
    addTearDown(backend.dispose);

    final outcome = await backend.selectTrack(UpdateTrack.dev);

    expect(outcome, isA<TrackSwitchUnsupported>());
    expect(backend.currentTrack, UpdateTrack.stable);
  });

  test('a selected track is actually persisted, not just held in memory',
      () async {
    final trackStore = UpdateTrackStore(
        settings: SettingsService(storage: _FakeAuthStorage()));
    final backend = ReleaseUpdateBackend(
      updater: _NoopUpdater(),
      currentVersion: '0.15.0',
      trackStore: trackStore,
    );
    addTearDown(backend.dispose);

    await backend.selectTrack(UpdateTrack.beta);

    expect(await trackStore.read(), UpdateTrack.beta);
  });

  test('Flatpak defers to the host, naming the remote', () async {
    final backend = FlatpakUpdateBackend(
      portal: _NoopPortal(),
      releaseNotesUrl: 'https://example.invalid/releases',
    );
    addTearDown(backend.dispose);

    final outcome = await backend.selectTrack(UpdateTrack.beta);
    expect(outcome, isA<TrackSwitchDeferred>());
    expect((outcome as TrackSwitchDeferred).instructions, contains('flatpak'));
  });

  test('Flatpak selecting beta names the beta remote and branch', () async {
    final backend = FlatpakUpdateBackend(
      portal: _NoopPortal(),
      releaseNotesUrl: 'https://example.invalid/releases',
    );
    addTearDown(backend.dispose);

    final outcome =
        await backend.selectTrack(UpdateTrack.beta) as TrackSwitchDeferred;

    expect(outcome.instructions, contains('mydia-beta'));
    expect(outcome.instructions, contains('//beta'));
  });

  test('Flatpak selecting stable names the stable remote and branch', () async {
    final backend = FlatpakUpdateBackend(
      portal: _NoopPortal(),
      releaseNotesUrl: 'https://example.invalid/releases',
    );
    addTearDown(backend.dispose);

    final outcome =
        await backend.selectTrack(UpdateTrack.stable) as TrackSwitchDeferred;

    expect(outcome.instructions, contains('install mydia '));
    expect(outcome.instructions, isNot(contains('mydia-beta')));
    expect(outcome.instructions, contains('//stable'));
  });

  group('Flatpak currentTrack follows the installed branch, not a guess', () {
    test('the literal stable branch reports stable', () {
      final backend = FlatpakUpdateBackend(
        portal: _NoopPortal(),
        releaseNotesUrl: 'https://example.invalid/releases',
        branch: 'stable',
      );
      addTearDown(backend.dispose);

      expect(backend.currentTrack, UpdateTrack.stable);
    });

    test('the beta branch reports beta', () {
      final backend = FlatpakUpdateBackend(
        portal: _NoopPortal(),
        releaseNotesUrl: 'https://example.invalid/releases',
        branch: 'beta',
      );
      addTearDown(backend.dispose);

      expect(backend.currentTrack, UpdateTrack.beta);
    });

    test(
        'an unrecognized branch reports beta rather than the conservative '
        'default', () {
      final backend = FlatpakUpdateBackend(
        portal: _NoopPortal(),
        releaseNotesUrl: 'https://example.invalid/releases',
        branch: 'nightly',
      );
      addTearDown(backend.dispose);

      expect(backend.currentTrack, UpdateTrack.beta);
    });

    test(
        'a null branch reports beta, matching flatpakReleaseNotesUrl\'s own '
        'resolution of the same input', () {
      final backend = FlatpakUpdateBackend(
        portal: _NoopPortal(),
        releaseNotesUrl: 'https://example.invalid/releases',
      );
      addTearDown(backend.dispose);

      expect(backend.currentTrack, UpdateTrack.beta);
    });
  });

  test('Sparkle offers stable and beta, and applies a switch', () async {
    var written = UpdateTrack.stable;
    final backend = SparkleUpdateBackend(
      checkForUpdates: () async {},
      readTrack: () async => written,
      writeTrack: (track) async {
        written = track;
        return true;
      },
    );
    addTearDown(backend.dispose);
    await backend.start();

    expect(backend.availableTracks, {UpdateTrack.stable, UpdateTrack.beta});
    expect(
        await backend.selectTrack(UpdateTrack.beta), isA<TrackSwitchApplied>());
    expect(written, UpdateTrack.beta);
  });

  test('a host that refuses the write is reported, not swallowed', () async {
    final backend = SparkleUpdateBackend(
      checkForUpdates: () async {},
      readTrack: () async => UpdateTrack.stable,
      writeTrack: (track) async => false,
    );
    addTearDown(backend.dispose);
    await backend.start();

    expect(await backend.selectTrack(UpdateTrack.beta),
        isA<TrackSwitchUnsupported>());
    expect(backend.currentTrack, UpdateTrack.stable);
  });
}

class _NoopPortal implements FlatpakPortal {
  @override
  Stream<FlatpakCommits> get updatesAvailable => const Stream.empty();

  @override
  Future<void> startMonitoring() async {}

  @override
  Stream<FlatpakProgress> update() => const Stream.empty();

  @override
  Future<void> restartIntoLatest() async {}

  @override
  Future<void> close() async {}
}
