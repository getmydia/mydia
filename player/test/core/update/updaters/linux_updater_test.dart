import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/updaters/linux_updater.dart';
import 'package:player/domain/models/app_update.dart';

void main() {
  String? opened;

  group('LinuxUpdater.installDirWritable', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('mydia-updater'));
    tearDown(() {
      // Restore the mode first, or the recursive delete fails on the
      // read-only case below.
      Process.runSync('chmod', ['0755', temp.path]);
      temp.deleteSync(recursive: true);
    });

    test('a writable directory reports writable', () {
      expect(LinuxUpdater.installDirWritable(path: temp.path), isTrue);
    });

    test(
        'a directory with the write bit set but no write permission reports '
        'not writable', () {
      // 0555 clears the owner write bit entirely, so this is not the shape
      // that fooled the old check. It covers a different case: a directory
      // that exists and is readable but refuses writes, so the probe fails
      // cleanly (returns false) instead of throwing.
      Process.runSync('chmod', ['0555', temp.path]);
      expect(LinuxUpdater.installDirWritable(path: temp.path), isFalse);
    });

    test('a directory we do not own reports not writable', () {
      // The shape that actually fooled the old check: /etc is 0755, so the
      // owner write bit is set, but root owns it and we do not. mode & 0x80
      // said writable here. A real probe does not.
      if (LinuxUpdater.installDirWritable(path: '/etc')) {
        markTestSkipped('running as root, DAC checks bypassed');
        return;
      }
      expect(LinuxUpdater.installDirWritable(path: '/etc'), isFalse);
    }, skip: !Platform.isLinux);

    test('a directory that does not exist reports not writable', () {
      expect(
        LinuxUpdater.installDirWritable(path: '${temp.path}/absent'),
        isFalse,
      );
    });

    test('the probe leaves nothing behind', () {
      LinuxUpdater.installDirWritable(path: temp.path);
      expect(temp.listSync(), isEmpty);
    });
  });

  group('LinuxUpdater.applyUpdate', () {
    test('does not download when the install directory is not writable',
        () async {
      // A URL that would fail loudly if it were ever fetched. The assertion is
      // that applyUpdate returns without touching it.
      final updater = LinuxUpdater(
        resolveInstallDir: () => '/proc/nonexistent-install-dir',
        openInBrowser: (url) async => opened = url,
      );

      await updater.applyUpdate(
        AppUpdate(
          version: '9.9.9',
          downloadUrl: 'https://127.0.0.1:1/never-fetched.tar.gz',
          releaseNotesUrl: 'https://example.invalid/releases/9.9.9',
          releaseTitle: 'Never fetched',
          publishedAt: DateTime.utc(2026, 9, 5),
        ),
      );

      expect(opened, 'https://example.invalid/releases/9.9.9');
    });
  });
}
