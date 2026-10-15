import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:player/core/player/subtitle_language_prefs.dart';

/// Gives every test in the calling `main()` an in-memory language prefs box.
///
/// Mounting `SubtitleTrackSelectorSheet` calls `SubtitleLanguagePrefs.load`,
/// which opens a disk-backed box when none is open and Hive can initialise.
/// A lone run cannot initialise it and fails fast. CI's bundled run can,
/// because an earlier file already pointed Hive at a temp directory it then
/// deleted, and the disk open never completes under the fake-async zone. It
/// stays registered as in flight, so the next `Hive.openBox` for that name,
/// in this file or a later one, waits on it forever. A box already open under
/// the name short-circuits `load` and `save`, which is all this does.
void useInMemorySubtitlePrefs() {
  Future<void> closeBox() async {
    if (Hive.isBoxOpen(SubtitleLanguagePrefs.boxName)) {
      await Hive.box<List<dynamic>>(SubtitleLanguagePrefs.boxName).close();
    }
  }

  setUp(() async {
    await closeBox();
    await Hive.openBox<List<dynamic>>(
      SubtitleLanguagePrefs.boxName,
      bytes: Uint8List(0),
    );
  });
  tearDown(closeBox);
}
