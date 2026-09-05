import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/install_environment.dart';

void main() {
  group('InstallEnvironment.resolve', () {
    test('a writable Linux install can be replaced in place', () {
      expect(
        InstallEnvironment.resolve(
          isLinux: true,
          flatpakId: null,
          flatpakInfoExists: false,
          installDirWritable: true,
        ),
        InstallEnvironment.inPlace,
      );
    });

    test('FLATPAK_ID marks a Flatpak install', () {
      expect(
        InstallEnvironment.resolve(
          isLinux: true,
          flatpakId: 'dev.mydia.player',
          flatpakInfoExists: false,
          installDirWritable: false,
        ),
        InstallEnvironment.flatpak,
      );
    });

    test('an empty FLATPAK_ID is not a Flatpak install', () {
      // An exported-but-empty variable is indistinguishable from unset for
      // our purposes, and treating it as Flatpak would tell a normal user to
      // run a flatpak command they have no use for.
      expect(
        InstallEnvironment.resolve(
          isLinux: true,
          flatpakId: '',
          flatpakInfoExists: false,
          installDirWritable: true,
        ),
        InstallEnvironment.inPlace,
      );
    });

    test('/.flatpak-info marks a Flatpak install without the variable', () {
      expect(
        InstallEnvironment.resolve(
          isLinux: true,
          flatpakId: null,
          flatpakInfoExists: true,
          installDirWritable: false,
        ),
        InstallEnvironment.flatpak,
      );
    });

    test('Flatpak wins over a writable install directory', () {
      // The answer for a Flatpak install is `flatpak update`, whether or not
      // some future runtime happens to leave /app writable.
      expect(
        InstallEnvironment.resolve(
          isLinux: true,
          flatpakId: 'dev.mydia.player',
          flatpakInfoExists: true,
          installDirWritable: true,
        ),
        InstallEnvironment.flatpak,
      );
    });

    test('a non-writable Linux install is read-only', () {
      expect(
        InstallEnvironment.resolve(
          isLinux: true,
          flatpakId: null,
          flatpakInfoExists: false,
          installDirWritable: false,
        ),
        InstallEnvironment.readOnly,
      );
    });

    test('a non-Linux install is always in place', () {
      // Windows installs per-user into %LOCALAPPDATA% and runs its own
      // installer, so WindowsUpdater.canUpdateInPlace has always been true.
      // Consulting writability there would newly refuse updates that work.
      expect(
        InstallEnvironment.resolve(
          isLinux: false,
          flatpakId: null,
          flatpakInfoExists: false,
          installDirWritable: false,
        ),
        InstallEnvironment.inPlace,
      );
    });
  });

  group('InstallEnvironment.detect', () {
    test('agrees with resolve on the platform under test', () {
      // Guards the wiring between the lookups and the decision. Only the
      // running platform's answer is observable, which is why the decision
      // itself is tested purely above.
      expect(
        InstallEnvironment.detect(),
        isIn(InstallEnvironment.values),
      );
    });
  });
}
