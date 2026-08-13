import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:player/core/player/subtitle_language_prefs.dart';

void main() {
  group('defaults', () {
    test('is a non-empty list regardless of the test locale', () {
      // The test environment's locale is whatever the harness sets, not
      // something this test controls -- so it asserts the shape of the
      // fallback rather than a specific language list.
      expect(SubtitleLanguagePrefs.defaults, isNotEmpty);
    });
  });

  group('Hive-backed load/save', () {
    late Directory tempDir;
    late Box<List> box;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('subtitle_language_prefs');
      Hive.init(tempDir.path);
      box = await Hive.openBox<List>(SubtitleLanguagePrefs.boxName);
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteBoxFromDisk(SubtitleLanguagePrefs.boxName);
      await tempDir.delete(recursive: true);
    });

    test('load returns the defaults when nothing has been saved', () async {
      expect(
          await SubtitleLanguagePrefs.load(), SubtitleLanguagePrefs.defaults);
    });

    test('save then load round-trips the language list', () async {
      await SubtitleLanguagePrefs.save(['es', 'en']);

      expect(await SubtitleLanguagePrefs.load(), ['es', 'en']);
    });

    test('a later save replaces an earlier one', () async {
      await SubtitleLanguagePrefs.save(['fr']);
      await SubtitleLanguagePrefs.save(['de', 'en']);

      expect(await SubtitleLanguagePrefs.load(), ['de', 'en']);
    });

    test('an empty saved list falls back to the defaults', () async {
      await SubtitleLanguagePrefs.save([]);

      expect(
          await SubtitleLanguagePrefs.load(), SubtitleLanguagePrefs.defaults);
    });

    test('discards an unreadable record instead of throwing', () async {
      // Written directly to the box, bypassing `save`, to simulate a record
      // this class never wrote -- an older format, or corruption.
      await box.put('languages', [1, 2, 3]);

      expect(
          await SubtitleLanguagePrefs.load(), SubtitleLanguagePrefs.defaults);
    });

    test('a fresh read sees what an earlier save wrote', () async {
      await SubtitleLanguagePrefs.save(['ja']);

      // Directly inspecting the box, not going through `load`, confirms the
      // write actually reached Hive rather than only living in some
      // in-memory fallback.
      expect(box.get('languages'), ['ja']);
    });
  });
}
