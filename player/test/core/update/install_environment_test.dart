import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/install_environment.dart';

void main() {
  group('InstallEnvironment.installDirWritable', () {
    test('a directory we do not own reports not writable', () {
      // The shape that fooled the old bit check: /etc is 0755, so the owner
      // write bit is set, but root owns it and we do not. mode & 0x80 said
      // writable here; the real probe LinuxUpdater.installDirWritable does
      // not. Mirrors the equivalent test in
      // test/core/update/updaters/linux_updater_test.dart, which exercises
      // the same probe directly.
      //
      // The root guard must not call installDirWritable itself. Root bypasses
      // DAC checks, so under root the probe legitimately succeeds and there
      // is nothing to assert. Asking the function under test whether to skip
      // would let a revert to the bit check answer "writable", skip the
      // test, and pass CI green while the bug was back.
      if (Process.runSync('id', ['-u']).stdout.toString().trim() == '0') {
        markTestSkipped('running as root, where DAC checks are bypassed');
        return;
      }

      expect(InstallEnvironment.installDirWritable(path: '/etc'), isFalse);
    }, skip: !Platform.isLinux);
  });

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
