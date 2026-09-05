import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/available_update.dart';

void main() {
  test('a release asset names its version', () {
    final update = AppUpdate(
      version: '0.15.0',
      downloadUrl: 'https://example.invalid/player-linux-v0.15.0.tar.gz',
      releaseNotesUrl: 'https://example.invalid/releases/0.15.0',
      releaseTitle: 'Faster library scans',
      publishedAt: DateTime.utc(2026, 8, 1),
    );

    expect(update.version, '0.15.0');
    expect(update.releaseNotesUrl, 'https://example.invalid/releases/0.15.0');
  });

  test('a Flatpak remote update names no version', () {
    final update = FlatpakRemoteUpdate(
      releaseNotesUrl: 'https://github.com/getmydia/mydia/releases/latest',
    );

    expect(update.version, isNull);
    expect(update.installedAwaitingRestart, isFalse);
  });

  test('an already-installed Flatpak update is awaiting a restart', () {
    final update = FlatpakRemoteUpdate(
      releaseNotesUrl: 'https://github.com/getmydia/mydia/releases/latest',
      installedAwaitingRestart: true,
    );

    expect(update.installedAwaitingRestart, isTrue);
  });

  group('flatpakReleaseNotesUrl', () {
    test('stable points at the latest release', () {
      expect(
        flatpakReleaseNotesUrl('stable'),
        'https://github.com/getmydia/mydia/releases/latest',
      );
    });

    test('beta points at the full list, because /latest skips prereleases', () {
      expect(
        flatpakReleaseNotesUrl('beta'),
        'https://github.com/getmydia/mydia/releases',
      );
    });

    test('an unknown or missing branch falls back to the full list', () {
      expect(
        flatpakReleaseNotesUrl(null),
        'https://github.com/getmydia/mydia/releases',
      );
    });
  });
}
