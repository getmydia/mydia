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
  /// The latest size chosen through [set], so a stored read that finishes
  /// after the viewer has already chosen cannot replace their choice.
  SubtitleSize? _selected;

  /// Tail of the write chain. Each write starts only after the previous one
  /// has finished, so the stepper's rapid taps reach storage in call order
  /// and the last selection is the one left persisted.
  Future<void> _pendingWrite = Future.value();

  @override
  Future<SubtitleSize> build() async {
    final stored =
        await ref.read(coreSettingsServiceProvider).getSubtitleSize();
    return _selected ?? stored;
  }

  /// Publishes before awaiting the write, so the text behind the subtitle
  /// sheet resizes on the same frame the viewer steps. A failed write keeps
  /// the new size for this session and is only logged, for the same reason
  /// as `StatsOverlayEnabled.set`: callers discard the returned future.
  /// Writes are serialized (see [_pendingWrite]) and a failed one does not
  /// break the chain.
  Future<void> set(SubtitleSize size) {
    _selected = size;
    state = AsyncData(size);
    final service = ref.read(coreSettingsServiceProvider);
    return _pendingWrite = _pendingWrite.then((_) async {
      try {
        await service.setSubtitleSize(size);
      } catch (e) {
        debugPrint('[SubtitleSizeSetting] Could not persist: $e');
      }
    });
  }
}
