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
/// [adopt] puts a rung into effect in memory — the widget both requests and
/// displays it from there. [remember] writes it to storage for the *next*
/// playback and is allowed to fail. [restart] tears the session down and
/// brings it back at that rung, throwing if it cannot; [isFallback]
/// distinguishes the two attempts, which the viewer is told apart.
/// [stillActive] reports whether the caller can still act at all (its widget
/// is still mounted). [onGaveUp] receives the second failure.
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
  required Future<void> Function(QualityRung rung, {required bool isFallback})
      restart,
  required bool Function() stillActive,
  required void Function(Object error) onGaveUp,
}) async {
  await _adoptAndRemember(selected, adopt, remember);

  try {
    await restart(selected, isFallback: false);
  } catch (error) {
    // Fall back to the rung that was working rather than stranding the
    // viewer on a black screen at a rung this file or server cannot serve.
    debugPrint(
        '[PlayerScreen] Quality change to ${selected.label} failed: $error');
    if (!stillActive()) return;
    await _adoptAndRemember(previous, adopt, remember);

    try {
      await restart(previous, isFallback: true);
    } catch (fallbackError) {
      debugPrint('[PlayerScreen] Restoring ${previous.label} failed too: '
          '$fallbackError');
      if (!stillActive()) return;
      onGaveUp(fallbackError);
    }
  }
}

/// Puts [rung] into effect in memory, then tries to remember it for the next
/// playback.
///
/// Both the order and the swallow are load-bearing. [adopt] is the only
/// channel the restart reads the rung from, so it happens first and is
/// synchronous — nothing can fail between choosing a rung and the restart
/// seeing it. [remember] goes through secure storage, which needs a keyring
/// on Linux desktop and can genuinely be unavailable, so its failure costs
/// the preference for next time and nothing else. Before this split, the
/// choice reached the restart *through* storage, and a swallowed write
/// failure silently restarted the session at the rung the viewer had just
/// replaced.
Future<void> _adoptAndRemember(
  QualityRung rung,
  void Function(QualityRung rung) adopt,
  Future<void> Function(QualityRung rung) remember,
) async {
  adopt(rung);

  try {
    await remember(rung);
  } catch (e) {
    debugPrint('[PlayerScreen] Could not save default quality: $e');
  }
}
