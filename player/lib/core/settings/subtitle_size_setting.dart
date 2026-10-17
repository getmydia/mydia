/// The device-level subtitle size, read by the player screen and written by
/// the settings row and the subtitle sheet.
library;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../player/subtitle_size.dart';
import 'settings_providers.dart';

part 'subtitle_size_setting.g.dart';

@riverpod
class SubtitleSizeSetting extends _$SubtitleSizeSetting {
  @override
  Future<SubtitleSize> build() =>
      ref.read(coreSettingsServiceProvider).getSubtitleSize();

  /// Publishes before awaiting the write, so the text behind the subtitle
  /// sheet resizes on the same frame the viewer steps. A failed write keeps
  /// the new size for this session and is only logged, for the same reason
  /// as `StatsOverlayEnabled.set`: callers discard the returned future.
  Future<void> set(SubtitleSize size) async {
    state = AsyncData(size);
    try {
      await ref.read(coreSettingsServiceProvider).setSubtitleSize(size);
    } catch (e) {
      debugPrint('[SubtitleSizeSetting] Could not persist: $e');
    }
  }
}
