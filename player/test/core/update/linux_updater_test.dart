import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/install_environment.dart';
import 'package:player/core/update/updaters/linux_updater.dart';
import 'package:player/domain/models/app_update.dart';

AppUpdate _update() => AppUpdate(
      version: '0.15.0',
      // .invalid is reserved and never resolves, so any attempt to download
      // fails loudly rather than reaching the network.
      downloadUrl: 'https://example.invalid/player-linux-v0.15.0.tar.gz',
      releaseNotesUrl: 'https://example.invalid/releases/0.15.0',
      releaseTitle: 'Faster library scans',
      publishedAt: DateTime.utc(2026, 8, 1),
    );

void main() {
  test('a Flatpak install cannot be updated in place', () {
    expect(
      LinuxUpdater(environment: InstallEnvironment.flatpak).canUpdateInPlace,
      isFalse,
    );
  });

  test('a writable install can be updated in place', () {
    expect(
      LinuxUpdater(environment: InstallEnvironment.inPlace).canUpdateInPlace,
      isTrue,
    );
  });

  test('a Flatpak install throws before downloading anything', () async {
    // The distinction that matters is StateError versus DioException. The old
    // code downloaded and extracted the whole archive before discovering it
    // could not write the install directory; if that order ever returns, the
    // unreachable .invalid host makes this fail as a DioException instead.
    await expectLater(
      LinuxUpdater(environment: InstallEnvironment.flatpak)
          .applyUpdate(_update()),
      throwsA(isA<StateError>()),
    );
  });

  test('a read-only install throws before downloading anything', () async {
    await expectLater(
      LinuxUpdater(environment: InstallEnvironment.readOnly)
          .applyUpdate(_update()),
      throwsA(
        allOf(isA<StateError>(), isNot(isA<DioException>())),
      ),
    );
  });
}
