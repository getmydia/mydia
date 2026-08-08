import 'package:flutter/material.dart';

import '../../domain/models/media_file.dart';
import 'smart_play_button.dart';

/// The detail hero's primary Play affordance: a bold "Play" label beside
/// [SmartPlayButton]'s auto-selecting play control.
///
/// Sits in the backdrop overlay's title row on both the show and movie detail
/// heroes, as the Row's non-flex trailing child. That is what pins it to the
/// hero's right edge: the sibling title column is [Expanded] and absorbs all
/// leftover width, while this control takes only its intrinsic size.
///
/// That non-flex position gives [SmartPlayButton] unbounded main-axis
/// constraints, which is only safe because `state:` is never passed through
/// here. If a future caller threads `state:` to this widget to restore the
/// labelled pill form, it must first give this control a bounded width —
/// otherwise `SmartPlayButton`'s `kPillCollapseWidth` check sees an infinite
/// `constraints.maxWidth`, the pill never collapses, and it overflows narrow
/// heroes.
class HeroPlayControl extends StatelessWidget {
  final List<MediaFile> files;
  final void Function(MediaFile) onFileSelected;

  const HeroPlayControl({
    super.key,
    required this.files,
    required this.onFileSelected,
  });

  @override
  Widget build(BuildContext context) {
    // MainAxisSize.min because a non-flex Row child receives unbounded
    // main-axis constraints. Under those RenderFlex sets canFlex = false and
    // falls back to the children's intrinsic size, so MainAxisSize.max happens
    // to behave identically here and MainAxisAlignment has no free space to
    // distribute. Stating min keeps the intent readable and keeps the widget
    // correct if it is ever placed under bounded constraints.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Play', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        SmartPlayButton(files: files, onFileSelected: onFileSelected),
      ],
    );
  }
}
