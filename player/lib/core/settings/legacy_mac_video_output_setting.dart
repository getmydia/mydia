/// The device-level "use the legacy video output" escape hatch for macOS,
/// read when playback picks its output and written by the diagnostics screen.
library;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'settings_providers.dart';

part 'legacy_mac_video_output_setting.g.dart';

@riverpod
class LegacyMacVideoOutput extends _$LegacyMacVideoOutput {
  @override
  Future<bool> build() =>
      ref.read(coreSettingsServiceProvider).getLegacyMacVideoOutput();

  /// Publishes the new value before awaiting the write. A failed write
  /// leaves the choice in place for this session and is only logged.
  Future<void> set(bool enabled) async {
    state = AsyncData(enabled);
    try {
      await ref
          .read(coreSettingsServiceProvider)
          .setLegacyMacVideoOutput(enabled);
    } catch (e) {
      debugPrint('[LegacyMacVideoOutput] Could not persist: $e');
    }
  }
}
