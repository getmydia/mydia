/// The device-level "use the legacy video output" escape hatch for macOS,
/// read when playback picks its output and written by the diagnostics screen.
library;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'settings_providers.dart';

part 'legacy_mac_video_output_setting.g.dart';

@riverpod
class LegacyMacVideoOutput extends _$LegacyMacVideoOutput {
  /// The viewer's choice in this provider's life. Wins over the stored
  /// value, so an initial read that started before [set] wrote cannot put
  /// the old value back.
  bool? _chosen;

  @override
  Future<bool> build() async {
    final stored =
        await ref.read(coreSettingsServiceProvider).getLegacyMacVideoOutput();
    return _chosen ?? stored;
  }

  /// Publishes the new value before awaiting the write. A failed write
  /// leaves the choice in place for this session and is only logged.
  Future<void> set(bool enabled) async {
    _chosen = enabled;
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
