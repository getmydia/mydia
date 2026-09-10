/// What the quality control shows, and whether it is offered at all.
///
/// Pure, so it can be tested without the playback chrome, which
/// `flutter test` cannot build (see `quality_choice.dart`).
library;

import '../../domain/models/quality_rung.dart';
import 'playback_plan.dart';

/// Whether the quality control has a real choice to offer.
///
/// Auto and Original differ whenever Auto could pick a rung (a non-empty
/// adaptive ladder) or the file plays losslessly (direct play or copy, where
/// Auto respects remembered failures and Original overrides them), so the
/// control shows even when the manual ladder is Original alone. A local file
/// has no session to switch and nothing to choose between.
bool qualityControlAvailable({
  required bool localFile,
  required PlaybackPlan? plan,
  required int? sourceHeight,
}) {
  if (localFile || plan == null) return false;
  final lossless = plan is DirectPlayPlan ||
      (plan is HlsPlan && plan.strategy == HlsStrategy.copy);
  return lossless ||
      deriveAdaptiveLadder(sourceHeight: sourceHeight).isNotEmpty;
}

/// The control's label.
///
/// Auto names itself; the picker's Auto row carries what it chose. Any other
/// choice shows what the server applied, which on a relay can sit below it.
String qualityControlLabel({
  required QualityRung selected,
  QualityRung? effective,
}) =>
    selected.isAuto ? selected.label : (effective ?? selected).label;

/// Explains a server-side limit, or null when the stream got what was asked.
///
/// Compares against the rung the plan requested rather than the viewer's
/// choice: under Auto that rung is Auto's own pick, and naming it as a limit
/// would blame the connection for a decision the player made.
String? qualityClampNote({
  required PlaybackPlan? plan,
  QualityRung? effective,
}) {
  if (plan is! HlsPlan || effective == null) return null;
  final effectiveHeight = effective.height;
  if (effectiveHeight == null) return null;
  final requestedHeight = plan.rung.height;
  if (requestedHeight != null && effectiveHeight >= requestedHeight) {
    return null;
  }
  return 'Limited to ${effective.label} by your connection';
}
