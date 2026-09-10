/// The quality picker's decision: put the chosen rung into effect, and if
/// that fails, put the one that was already working back and try once more.
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/quality_rung.dart';
import 'playback_plan.dart';

/// Whether a quality pick has to reopen the source.
///
/// A first attempt whose plan delivers the same bytes as what is playing
/// reopens nothing: only the choice changes. A rollback always reopens,
/// because the attempt it undoes may have failed after the player had
/// already moved to the new media, and the plan on record would then
/// describe bytes that are no longer on screen.
bool qualityPickNeedsReopen({
  required PlaybackPlan next,
  required PlaybackPlan? current,
  required bool isFallback,
}) =>
    isFallback || current == null || !sameDelivery(next, current);

/// Puts [selected] into effect, restoring [previous] if that fails.
///
/// Extracted from [_PlayerScreenState._showQualitySelector] for the same
/// reason as `shouldRestartForSeek` in `seek_decision.dart`: the widget path
/// cannot be driven under `flutter test`. `_waitForPlaylist` polls a real URL
/// that `flutter_test`'s `HttpOverrides` answers with 400 on every attempt,
/// so the screen reaches its error state before the chrome that owns the
/// quality button is ever built, and the picker can never be tapped. This is
/// the riskiest decision in the quality change and the one most worth
/// pinning, so it lives where a fake [restart] that throws can exercise it.
///
/// [adopt] puts a rung into effect in memory, synchronously and first — it
/// is the only channel [restart] reads the rung from, so nothing can happen
/// between choosing a rung and the restart seeing it. [restart] tears the
/// session down and brings it back at that rung: it resolves to `true` once
/// the rung is actually in effect (including a same-delivery pick that
/// reopens nothing, since the choice is then in effect either way), to
/// `false` if some other source switch took over first and this pick is
/// abandoned quietly, and throws if the attempt itself failed. [remember]
/// writes the rung to storage for the *next* playback and is allowed to
/// fail; it only runs once [restart] reports `true`, since persisting a rung
/// before the restart has landed can race a fallback that starts mid-await
/// and store a rung that never actually played. [isFallback] distinguishes
/// the two attempts, which the viewer is told apart. [stillActive] reports
/// whether the caller can still act at all (its widget is still mounted).
/// [onGaveUp] receives the second failure.
///
/// The retry is deliberately single. If returning to the rung that was
/// already working also fails, the problem is not the quality choice, and
/// another teardown would only cost the viewer more time before showing them
/// the same error. [onGaveUp] is where they land on the error screen instead.
Future<void> applyQualityChoice({
  required QualityRung selected,
  required QualityRung previous,
  required void Function(QualityRung rung) adopt,
  required Future<void> Function(QualityRung rung) remember,
  required Future<bool> Function(QualityRung rung, {required bool isFallback})
      restart,
  required bool Function() stillActive,
  required void Function(Object error) onGaveUp,
}) async {
  adopt(selected);

  try {
    if (!await restart(selected, isFallback: false)) {
      debugPrint('[PlayerScreen] Quality change to ${selected.label} '
          'abandoned: another source switch took over');
      return;
    }
    await _remember(selected, remember);
  } catch (error) {
    // Fall back to the rung that was working rather than stranding the
    // viewer on a black screen at a rung this file or server cannot serve.
    debugPrint(
        '[PlayerScreen] Quality change to ${selected.label} failed: $error');
    if (!stillActive()) return;
    adopt(previous);

    try {
      if (!await restart(previous, isFallback: true)) {
        debugPrint('[PlayerScreen] Restoring ${previous.label} abandoned: '
            'another source switch took over');
        return;
      }
      await _remember(previous, remember);
    } catch (fallbackError) {
      debugPrint('[PlayerScreen] Restoring ${previous.label} failed too: '
          '$fallbackError');
      if (!stillActive()) return;
      onGaveUp(fallbackError);
    }
  }
}

/// Persists [rung] for the next playback, swallowing failure.
///
/// Only called once [restart] has reported the rung is actually in effect;
/// see [applyQualityChoice]. [remember] goes through secure storage, which
/// needs a keyring on Linux desktop and can genuinely be unavailable, so its
/// failure costs the preference for next time and nothing else.
Future<void> _remember(
  QualityRung rung,
  Future<void> Function(QualityRung rung) remember,
) async {
  try {
    await remember(rung);
  } catch (e) {
    debugPrint('[PlayerScreen] Could not save default quality: $e');
  }
}
