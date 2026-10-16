import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/source_artwork.dart';

/// A calendar entry's landscape picture: the episode still or show backdrop,
/// then the poster cropped to fill, then a plain fill. A picture that fails
/// falls to the next one, so the slot is never blank.
class CalendarArtwork extends StatelessWidget {
  const CalendarArtwork({super.key, required this.entry});

  final ItemSummary entry;

  @override
  Widget build(BuildContext context) {
    const plain = ColoredBox(color: AppColors.surfaceVariant);
    final sourceId = entry.ref.sourceId;
    final poster = entry.poster;
    final backdrop = entry.backdrop;

    final posterOrPlain = poster == null
        ? plain
        : SourceArtworkImage(sourceId: sourceId, art: poster, fallback: plain);

    return backdrop == null
        ? posterOrPlain
        : SourceBackdrop(
            sourceId: sourceId,
            art: backdrop,
            fallback: posterOrPlain,
          );
  }
}
