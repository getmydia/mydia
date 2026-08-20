import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/remote/remote_control_settings.dart';

void main() {
  late Directory tempDir;
  late Box<dynamic> box;
  var boxCounter = 0;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('remote_control_settings');
    Hive.init(tempDir.path);
    // A unique box name per test: Hive caches open boxes by name, so a shared
    // name leaks state between tests in the same run.
    boxCounter += 1;
    box = await Hive.openBox<dynamic>('remote_control_$boxCounter');
  });

  tearDown(() async {
    await box.close();
    await tempDir.delete(recursive: true);
  });

  group('RemoteControlSettings', () {
    test('defaults to controllable, so a freshly paired device just appears',
        () async {
      // The cost is an idle QUIC endpoint. Defaulting off would mean every new
      // device is invisible in the picker with no hint why.
      final settings = RemoteControlSettings(box: box);
      expect(await settings.controllableEnabled(), isTrue);
    });

    test('remembers an explicit opt-out', () async {
      final settings = RemoteControlSettings(box: box);
      await settings.setControllable(false);

      expect(await settings.controllableEnabled(), isFalse);

      final reopened = RemoteControlSettings(box: box);
      expect(await reopened.controllableEnabled(), isFalse);
    });

    test('remembers an explicit opt-in after an opt-out', () async {
      final settings = RemoteControlSettings(box: box);
      await settings.setControllable(false);
      await settings.setControllable(true);

      expect(await settings.controllableEnabled(), isTrue);
    });
  });
}
