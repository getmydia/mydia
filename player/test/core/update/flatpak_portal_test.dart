import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/flatpak_portal.dart';

void main() {
  group('FlatpakCommits.fromDict', () {
    test('a newer remote commit is an update ready to install', () {
      final commits = FlatpakCommits.fromDict({
        'running-commit': const DBusString('aaa'),
        'local-commit': const DBusString('aaa'),
        'remote-commit': const DBusString('bbb'),
      });

      expect(commits.updateReady, isTrue);
      expect(commits.awaitingRestart, isFalse);
    });

    test('a local commit ahead of the running one only needs a restart', () {
      final commits = FlatpakCommits.fromDict({
        'running-commit': const DBusString('aaa'),
        'local-commit': const DBusString('bbb'),
        'remote-commit': const DBusString('bbb'),
      });

      expect(commits.updateReady, isFalse);
      expect(commits.awaitingRestart, isTrue);
    });

    test('all three equal means nothing to do', () {
      final commits = FlatpakCommits.fromDict({
        'running-commit': const DBusString('aaa'),
        'local-commit': const DBusString('aaa'),
        'remote-commit': const DBusString('aaa'),
      });

      expect(commits.updateReady, isFalse);
      expect(commits.awaitingRestart, isFalse);
    });

    test('missing keys claim nothing', () {
      final commits = FlatpakCommits.fromDict({});

      expect(commits.updateReady, isFalse);
      expect(commits.awaitingRestart, isFalse);
    });
  });

  group('FlatpakProgress.fromDict', () {
    test('decodes a running step', () {
      final progress = FlatpakProgress.fromDict({
        'progress': const DBusUint32(42),
        'status': const DBusUint32(0),
      });

      expect(progress.status, FlatpakProgressStatus.running);
      expect(progress.progress, 42);
    });

    test(
        'decodes the empty transaction the portal reports when there is '
        'nothing to install', () {
      final progress = FlatpakProgress.fromDict({
        'status': const DBusUint32(1),
      });

      expect(progress.status, FlatpakProgressStatus.empty);
    });

    test('decodes completion', () {
      final progress = FlatpakProgress.fromDict({
        'status': const DBusUint32(2),
        'progress': const DBusUint32(100),
      });

      expect(progress.status, FlatpakProgressStatus.done);
    });

    test('decodes a failure and keeps its message and error name', () {
      final progress = FlatpakProgress.fromDict({
        'status': const DBusUint32(3),
        'error': const DBusString('org.freedesktop.Flatpak.Error'),
        'error_message': const DBusString('While pulling: connection reset'),
      });

      expect(progress.status, FlatpakProgressStatus.failed);
      expect(progress.errorMessage, 'While pulling: connection reset');
      expect(progress.errorName, 'org.freedesktop.Flatpak.Error');
    });

    test('an unknown status is treated as a failure rather than success', () {
      final progress = FlatpakProgress.fromDict({
        'status': const DBusUint32(99),
      });

      expect(progress.status, FlatpakProgressStatus.failed);
    });
  });

  group('flatpakByteString', () {
    test('terminates with a NUL, which is what a GVariant bytestring is', () {
      // gdbus renders these as b'/app'. Dropping the terminator sends the
      // portal a path it will not recognise.
      expect(flatpakByteString('/app'), [47, 97, 112, 112, 0]);
    });
  });
}
