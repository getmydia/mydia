import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/backends/flatpak_update_backend.dart';
import 'package:player/core/update/backends/release_update_backend.dart';
import 'package:player/core/update/backends/sparkle_update_backend.dart';
import 'package:player/core/update/flatpak_environment.dart';
import 'package:player/core/update/flatpak_portal.dart';
import 'package:player/core/update/platform_updater.dart';
import 'package:player/core/update/update_host.dart';
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

const _linux = UpdateHost(
  isWeb: false,
  isAndroid: false,
  isIOS: false,
  isMacOS: false,
  isWindows: false,
  isLinux: true,
);

const _sideloadedAndroid = UpdateHost(
  isWeb: false,
  isAndroid: true,
  isIOS: false,
  isMacOS: false,
  isWindows: false,
  isLinux: false,
  installedFromPlay: false,
);

const _playAndroid = UpdateHost(
  isWeb: false,
  isAndroid: true,
  isIOS: false,
  isMacOS: false,
  isWindows: false,
  isLinux: false,
  installedFromPlay: true,
);

void main() {
  group('supportsInAppUpdates', () {
    test('web and iOS update elsewhere', () {
      for (final host in [
        const UpdateHost(
            isWeb: true,
            isAndroid: false,
            isIOS: false,
            isMacOS: false,
            isWindows: false,
            isLinux: false),
        const UpdateHost(
            isWeb: false,
            isAndroid: false,
            isIOS: true,
            isMacOS: false,
            isWindows: false,
            isLinux: false),
      ]) {
        expect(host.supportsInAppUpdates, isFalse);
      }
    });

    test('a sideloaded Android install updates itself', () {
      const host = UpdateHost(
        isWeb: false,
        isAndroid: true,
        isIOS: false,
        isMacOS: false,
        isWindows: false,
        isLinux: false,
        installedFromPlay: false,
      );
      expect(host.supportsInAppUpdates, isTrue);
    });

    test('a Play install does not', () {
      const host = UpdateHost(
        isWeb: false,
        isAndroid: true,
        isIOS: false,
        isMacOS: false,
        isWindows: false,
        isLinux: false,
        installedFromPlay: true,
      );
      expect(host.supportsInAppUpdates, isFalse);
    });

    test('desktop updates in app', () {
      expect(_linux.supportsInAppUpdates, isTrue);
    });
  });

  group('createUpdateBackend', () {
    test('web gets no backend at all', () {
      final backend = createUpdateBackend(
        const UpdateHost(
            isWeb: true,
            isAndroid: false,
            isIOS: false,
            isMacOS: false,
            isWindows: false,
            isLinux: false),
        currentVersion: '0.15.0',
      );

      expect(backend, isNull);
    });

    test('a Linux tarball install gets the release backend', () {
      final backend = createUpdateBackend(
        _linux,
        currentVersion: '0.15.0',
        archiveUpdater: _NoopUpdater.new,
      );

      expect(backend, isA<ReleaseUpdateBackend>());
    });

    test(
        'a Linux tarball install never offers Dev, because none is '
        'published for it', () {
      final backend = createUpdateBackend(
        _linux,
        currentVersion: '0.15.0',
        archiveUpdater: _NoopUpdater.new,
      ) as ReleaseUpdateBackend;

      expect(backend.availableTracks, {UpdateTrack.stable, UpdateTrack.beta});
    });

    test('a sideloaded Android install gets the release backend', () {
      final backend = createUpdateBackend(
        _sideloadedAndroid,
        currentVersion: '0.15.0',
        archiveUpdater: _NoopUpdater.new,
      );

      expect(backend, isA<ReleaseUpdateBackend>());
    });

    test(
        'a sideloaded Android install offers Dev too, since it is the one '
        'platform that publishes it', () {
      final backend = createUpdateBackend(
        _sideloadedAndroid,
        currentVersion: '0.15.0',
        archiveUpdater: _NoopUpdater.new,
      ) as ReleaseUpdateBackend;

      expect(
        backend.availableTracks,
        {UpdateTrack.stable, UpdateTrack.beta, UpdateTrack.dev},
      );
    });

    test('a Play install gets no backend at all', () {
      final backend = createUpdateBackend(
        _playAndroid,
        currentVersion: '0.15.0',
        archiveUpdater: _NoopUpdater.new,
      );

      expect(backend, isNull);
    });

    test(
        'a desktop platform with no concrete updater produces no backend, '
        'so no dead update row can appear', () {
      final backend = createUpdateBackend(
        _linux,
        currentVersion: '0.15.0',
        archiveUpdater: () => null,
      );

      expect(backend, isNull);
    });

    test('a Flatpak install gets the portal backend', () {
      final backend = createUpdateBackend(
        const UpdateHost(
            isWeb: false,
            isAndroid: false,
            isIOS: false,
            isMacOS: false,
            isWindows: false,
            isLinux: true,
            isFlatpak: true,
            flatpakBranch: 'stable'),
        currentVersion: '0.15.0',
        portalFactory: _NoopPortal.new,
      );

      expect(backend, isA<FlatpakUpdateBackend>());
    });

    test('macOS gets Sparkle', () {
      final backend = createUpdateBackend(
        const UpdateHost(
            isWeb: false,
            isAndroid: false,
            isIOS: false,
            isMacOS: true,
            isWindows: false,
            isLinux: false),
        currentVersion: '0.15.0',
      );

      expect(backend, isA<SparkleUpdateBackend>());
    });
  });

  group('UpdateHost construction', () {
    test('a host cannot claim Flatpak without claiming Linux', () {
      expect(
        () => UpdateHost(
          isWeb: false,
          isAndroid: false,
          isIOS: false,
          isMacOS: false,
          isWindows: true,
          isLinux: false,
          isFlatpak: true,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('UpdateHost.from', () {
    late Directory temp;

    setUp(
        () => temp = Directory.systemTemp.createTempSync('mydia-update-host'));
    tearDown(() => temp.deleteSync(recursive: true));

    String writeInfo() {
      final file = File('${temp.path}/flatpak-info');
      file.writeAsStringSync('[Instance]\nbranch=stable\n');
      return file.path;
    }

    test('Linux plus a Flatpak environment carries isFlatpak and the branch',
        () {
      final host = UpdateHost.from(
        isWeb: false,
        isAndroid: false,
        isIOS: false,
        isMacOS: false,
        isWindows: false,
        isLinux: true,
        flatpak: FlatpakEnvironment(infoPath: writeInfo()),
      );

      expect(host.isFlatpak, isTrue);
      expect(host.flatpakBranch, 'stable');
    });

    test('Windows plus the same Flatpak environment reports neither', () {
      final host = UpdateHost.from(
        isWeb: false,
        isAndroid: false,
        isIOS: false,
        isMacOS: false,
        isWindows: true,
        isLinux: false,
        flatpak: FlatpakEnvironment(infoPath: writeInfo()),
      );

      expect(host.isFlatpak, isFalse);
      expect(host.flatpakBranch, isNull);
    });

    test('Linux plus a non-Flatpak environment reports neither', () {
      final host = UpdateHost.from(
        isWeb: false,
        isAndroid: false,
        isIOS: false,
        isMacOS: false,
        isWindows: false,
        isLinux: true,
        flatpak: FlatpakEnvironment(infoPath: '${temp.path}/absent'),
      );

      expect(host.isFlatpak, isFalse);
      expect(host.flatpakBranch, isNull);
    });
  });
}
