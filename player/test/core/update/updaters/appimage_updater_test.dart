import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/updaters/appimage_updater.dart';

void main() {
  group('AppImageUpdater.resolveAppImagePath', () {
    test('returns APPIMAGE when set', () {
      expect(
        AppImageUpdater.resolveAppImagePath(
          {'APPIMAGE': '/home/u/Apps/Mydia_Player-x86_64.AppImage'},
        ),
        '/home/u/Apps/Mydia_Player-x86_64.AppImage',
      );
    });

    test('unset is not an AppImage', () {
      expect(AppImageUpdater.resolveAppImagePath(const {}), isNull);
    });

    test('empty is not an AppImage', () {
      // An exported-but-empty variable, the same call InstallEnvironment
      // makes for FLATPAK_ID.
      expect(AppImageUpdater.resolveAppImagePath({'APPIMAGE': ''}), isNull);
    });
  });
}
