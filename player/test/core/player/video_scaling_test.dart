import 'dart:io';

import 'package:flutter/painting.dart' show BoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:player/core/player/video_scaling.dart';

void main() {
  group('VideoScaling', () {
    test('maps to the BoxFit media_kit draws with', () {
      expect(VideoScaling.fit.boxFit, BoxFit.contain);
      expect(VideoScaling.fill.boxFit, BoxFit.cover);
    });

    test('toggled flips between the two modes', () {
      expect(VideoScaling.fit.toggled, VideoScaling.fill);
      expect(VideoScaling.fill.toggled, VideoScaling.fit);
    });

    test('names each mode in its toast', () {
      expect(VideoScaling.fit.toastMessage, 'Fit: whole picture');
      expect(VideoScaling.fill.toastMessage, 'Fill: cropped to screen');
    });
  });

  group('VideoScalingPrefs', () {
    late Directory tempDir;
    late Box<String> box;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('video_scaling_prefs');
      Hive.init(tempDir.path);
      box = await Hive.openBox<String>(VideoScalingPrefs.boxName);
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteBoxFromDisk(VideoScalingPrefs.boxName);
      await tempDir.delete(recursive: true);
    });

    test('load returns fit when nothing has been saved', () async {
      expect(await VideoScalingPrefs.load(), VideoScaling.fit);
    });

    test('save then load round-trips', () async {
      await VideoScalingPrefs.save(VideoScaling.fill);

      expect(await VideoScalingPrefs.load(), VideoScaling.fill);
    });

    test('an unknown stored value falls back to fit', () async {
      // Written directly, bypassing `save`, to simulate a value from a
      // future build that has a mode this one does not know.
      await box.put('scaling', 'stretch');

      expect(await VideoScalingPrefs.load(), VideoScaling.fit);
    });
  });
}
