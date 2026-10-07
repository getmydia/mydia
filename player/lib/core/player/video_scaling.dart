import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart' show BoxFit;
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../storage/app_hive.dart';

/// How the video fills the player when its shape differs from the screen's.
///
/// Two modes on purpose. Stretch distorts the picture and forced aspect
/// ratios answer a question nobody has asked; Fit and Fill are what the
/// "fullscreen still has bars" complaint is about.
enum VideoScaling {
  /// The whole picture, with black bars where the shapes differ.
  fit,

  /// The screen covered, with the picture's edges cropped.
  fill;

  BoxFit get boxFit => switch (this) {
        VideoScaling.fit => BoxFit.contain,
        VideoScaling.fill => BoxFit.cover,
      };

  VideoScaling get toggled => switch (this) {
        VideoScaling.fit => VideoScaling.fill,
        VideoScaling.fill => VideoScaling.fit,
      };

  /// Confirms the change, which matters when the video already matches the
  /// screen and the two modes look identical.
  String get toastMessage => switch (this) {
        VideoScaling.fit => 'Fit: whole picture',
        VideoScaling.fill => 'Fill: cropped to screen',
      };
}

/// Remembers the viewer's [VideoScaling] on this device.
///
/// Device-local, never synced: the right mode depends on the screen, so a
/// phone and a TV on the same account want different answers. The same
/// static-facade shape as `SubtitleLanguagePrefs`, and the same trade: any
/// failure to open, read or write the box falls back to [VideoScaling.fit]
/// rather than throwing, so a broken box costs the feature its memory, never
/// the feature itself.
class VideoScalingPrefs {
  static const boxName = 'video_scaling';

  /// There is one setting, so one key.
  static const _key = 'scaling';

  static Future<VideoScaling> load() async {
    try {
      final box = await _box();
      final saved = box.get(_key);
      return VideoScaling.values.asNameMap()[saved] ?? VideoScaling.fit;
    } catch (e) {
      debugPrint('[VideoScalingPrefs] Box unavailable, using fit: $e');
      return VideoScaling.fit;
    }
  }

  static Future<void> save(VideoScaling scaling) async {
    try {
      final box = await _box();
      await box.put(_key, scaling.name);
    } catch (e) {
      debugPrint('[VideoScalingPrefs] Box unavailable, not persisting: $e');
    }
  }

  static Future<Box<String>> _box() async {
    if (Hive.isBoxOpen(boxName)) return Hive.box<String>(boxName);
    await initAppHive();
    return Hive.openBox<String>(boxName);
  }
}
