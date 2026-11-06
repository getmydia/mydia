import 'package:flutter/material.dart';

import '../../core/focus/focus_memory.dart';
import '../../core/player/input_capabilities.dart';
import '../../domain/models/media_file.dart';
import '../../l10n/l10n.dart';
import 'smart_play_button.dart';

/// The detail hero's primary Play affordance: [SmartPlayButton]'s white
/// "Play" (or "Resume") pill, with the auto-selected version beside it.
///
/// Sits in the backdrop overlay's title row on both the show and movie detail
/// heroes, as the Row's non-flex trailing child. That is what pins it to the
/// hero's right edge: the sibling title column is [Expanded] and absorbs all
/// leftover width, while this control takes only its intrinsic size.
///
/// That non-flex position gives [SmartPlayButton] unbounded main-axis
/// constraints, which is only safe because `state:` is never passed through
/// here. If a future caller threads `state:` to this widget to restore the
/// labelled pill form, it must first give this control a bounded width,
/// otherwise `SmartPlayButton`'s `kPillCollapseWidth` check sees an infinite
/// `constraints.maxWidth`, the pill never collapses, and it overflows narrow
/// heroes.
class HeroPlayControl extends StatelessWidget {
  final List<MediaFile> files;
  final void Function(MediaFile) onFileSelected;

  /// Label the button "Resume" instead of "Play".
  final bool resume;

  const HeroPlayControl({
    super.key,
    required this.files,
    required this.onFileSelected,
    this.resume = false,
  });

  /// The key of Play's section on the television tier, for tests.
  static const sectionKey = ValueKey('hero-play-section');

  @override
  Widget build(BuildContext context) {
    final button = SmartPlayButton(
      files: files,
      onFileSelected: onFileSelected,
      playLabel: resume ? context.l10n.commonResume : context.l10n.commonPlay,
    );
    if (!InputCapabilities.directionalPrimary) return button;
    // Play is a section of its own in the detail page's `FocusMemoryColumn`,
    // above the hero's button bar: that is what lets DOWN from Play reach the
    // bar, which the geometric search misses because the bar sits at the
    // other side of the hero. Play and the version picker beside it are its
    // items (see `SmartPlayButton`), so a first entry lands on Play and a
    // return lands on whichever of the two the viewer left.
    return FocusMemoryRegion(
      debugLabel: 'hero-play',
      child: KeyedSubtree(key: sectionKey, child: button),
    );
  }
}
