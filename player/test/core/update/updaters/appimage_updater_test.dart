import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/updaters/appimage_updater.dart';
import 'package:player/domain/models/available_update.dart';

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

  group('AppImageUpdater.applyUpdate', () {
    late Directory temp;
    late String appImage;
    String? launched;
    String? opened;
    var exited = false;

    // ELF magic, then the AppImage type 2 marker at offset 8.
    final validAppImage = [
      0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0, 0x41, 0x49, 0x02, //
      ...List.filled(64, 0),
    ];

    AppUpdate update() => AppUpdate(
          version: '9.9.9',
          downloadUrl:
              'https://example.invalid/mydia-player-linux-v9.9.9-x86_64.AppImage',
          releaseNotesUrl: 'https://example.invalid/releases/9.9.9',
          releaseTitle: 'v9.9.9',
          publishedAt: DateTime.utc(2026, 9, 27),
        );

    AppImageUpdater updater({required List<int> Function() bytes}) =>
        AppImageUpdater(
          appImagePath: appImage,
          download: (url, destination, onProgress) async {
            File(destination).writeAsBytesSync(bytes());
            onProgress?.call(1.0);
          },
          launch: (path) async => launched = path,
          openInBrowser: (url) async => opened = url,
          exitApp: () => exited = true,
        );

    setUp(() {
      temp = Directory.systemTemp.createTempSync('mydia-appimage');
      appImage = '${temp.path}/Mydia_Player-x86_64.AppImage';
      File(appImage).writeAsStringSync('old build');
      launched = null;
      opened = null;
      exited = false;
    });
    tearDown(() {
      Process.runSync('chmod', ['0755', temp.path]);
      temp.deleteSync(recursive: true);
    });

    test('replaces the AppImage, keeps its name, relaunches it', () async {
      await updater(bytes: () => validAppImage).applyUpdate(update());

      expect(File(appImage).readAsBytesSync(), validAppImage);
      // Owner execute bit.
      expect(File(appImage).statSync().mode & 0x40, isNot(0));
      expect(launched, appImage);
      expect(exited, isTrue);
      expect(temp.listSync().map((e) => e.path), [appImage]);
    });

    test('a download that is not an AppImage leaves the original alone',
        () async {
      await expectLater(
        updater(bytes: () => '<html>502</html>'.codeUnits)
            .applyUpdate(update()),
        throwsA(isA<AppImageUpdateException>()),
      );

      expect(File(appImage).readAsStringSync(), 'old build');
      expect(temp.listSync().map((e) => e.path), [appImage]);
      expect(launched, isNull);
      expect(exited, isFalse);
    });

    test('a failed download leaves the original alone', () async {
      final failing = AppImageUpdater(
        appImagePath: appImage,
        download: (url, destination, onProgress) async {
          File(destination).writeAsBytesSync([0x7f, 0x45]);
          throw const SocketException('connection reset');
        },
        launch: (path) async => launched = path,
        exitApp: () => exited = true,
      );

      await expectLater(
          failing.applyUpdate(update()), throwsA(isA<SocketException>()));

      expect(File(appImage).readAsStringSync(), 'old build');
      expect(temp.listSync().map((e) => e.path), [appImage]);
      expect(exited, isFalse);
    });

    test('an unwritable directory opens the release page without downloading',
        () async {
      if (Process.runSync('id', ['-u']).stdout.toString().trim() == '0') {
        markTestSkipped('running as root, where DAC checks are bypassed');
        return;
      }
      Process.runSync('chmod', ['0555', temp.path]);
      var downloaded = false;
      final readOnly = AppImageUpdater(
        appImagePath: appImage,
        download: (url, destination, onProgress) async => downloaded = true,
        openInBrowser: (url) async => opened = url,
        exitApp: () => exited = true,
      );

      expect(readOnly.canUpdateInPlace, isFalse);
      await readOnly.applyUpdate(update());

      expect(downloaded, isFalse);
      expect(opened, 'https://example.invalid/releases/9.9.9');
      expect(exited, isFalse);
    }, skip: !Platform.isLinux);
  });
}
