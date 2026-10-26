import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/palette.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/sources/item.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/play_button.dart';
import '../detail/detail_links.dart';
import 'calendar_artwork.dart';
import 'calendar_dates.dart';
import 'calendar_play.dart';
import 'calendar_timeline.dart';

/// A playable calendar entry, large: a landscape picture with a play button,
/// then its title and numbering.
///
/// The body opens the detail screen and the play button plays: two targets,
/// so a mistap on the body cannot start playback, and the D-pad has a
/// horizontal stop to land on.
class CalendarCard extends ConsumerWidget {
  const CalendarCard({
    super.key,
    required this.entry,
    required this.today,
    required this.imageHeight,
  });

  final ItemSummary entry;

  /// Injected rather than read from the clock so tests are deterministic.
  final DateTime today;

  /// From [TimelineLayout.cardImageHeight].
  final double imageHeight;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(12));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final id = entry.ref.externalId;
    final day = entry.day;
    final isToday = day != null && isSameDay(day, today);

    return Material(
      color: palette.surface,
      borderRadius: _radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('calendar-card-$id'),
        onTap: () => context.push(detailLocation(SourceTarget(entry.ref))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: imageHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CalendarArtwork(entry: entry),
                  if (isToday)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _NewChip(key: ValueKey('calendar-new-$id')),
                    ),
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: PlayButton(
                      key: ValueKey('calendar-play-$id'),
                      onPressed: () => playCalendarEntry(context, ref, entry),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.calendarTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: TimelineLayout.titleLine / 14,
                      fontWeight: FontWeight.w600,
                      color: palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    context.l10n.calendarSubtitle(entry),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: TimelineLayout.subtitleLine / 12,
                      color: palette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewChip extends StatelessWidget {
  const _NewChip({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.overlayDark,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        context.l10n.calendarNewToday,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: context.palette.textPrimary,
        ),
      ),
    );
  }
}
