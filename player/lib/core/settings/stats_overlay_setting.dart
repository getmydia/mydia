/// The device-level "Stats for nerds" flag, read by the player screen and
/// written by the settings screen and the quality sheet.
library;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'settings_providers.dart';

part 'stats_overlay_setting.g.dart';

@riverpod
class StatsOverlayEnabled extends _$StatsOverlayEnabled {
  @override
  Future<bool> build() =>
      ref.read(coreSettingsServiceProvider).getStatsOverlayEnabled();

  /// Publishes the new value before awaiting the write, so the panel
  /// appears or disappears on the same frame the switch moves. A failed
  /// write leaves the panel where the viewer put it for this session and
  /// is not worth an error surface or a rollback of the optimistic state --
  /// both call sites discard the returned future, so a failure that escaped
  /// uncaught would surface as an unhandled asynchronous error instead of
  /// anything anyone sees.
  Future<void> set(bool enabled) async {
    state = AsyncData(enabled);
    try {
      await ref
          .read(coreSettingsServiceProvider)
          .setStatsOverlayEnabled(enabled);
    } catch (e) {
      debugPrint('[StatsOverlayEnabled] Could not persist: $e');
    }
  }
}
