import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/backends/flatpak_update_backend.dart';
import 'package:player/core/update/backends/release_update_backend.dart';
import 'package:player/core/update/backends/sparkle_update_backend.dart';
import 'package:player/core/update/flatpak_portal.dart';
import 'package:player/core/update/platform_updater.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_track.dart';
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
