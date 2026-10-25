import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/palette.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/sources/item.dart';
import '../../../l10n/l10n.dart';
import '../detail/detail_links.dart';
import 'calendar_artwork.dart';
import 'calendar_dates.dart';
import 'calendar_timeline.dart';

/// A calendar entry that cannot be played yet, as one compact line: a dimmed
/// thumbnail, its title, its numbering and whether it is upcoming or missing.
///
/// Playable entries get a [CalendarCard] instead; the size is the signal.
/// Tapping the row opens the detail screen.
class CalendarRow extends StatelessWidget {
  const CalendarRow({super.key, required this.entry, required this.today});

  final ItemSummary entry;

  /// Injected rather than read from the clock so tests are deterministic.
  final DateTime today;

  bool get _isFuture {
    final day = entry.day;
    return day != null && day.isAfter(truncateToDay(today));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final id = entry.ref.externalId;

    return InkWell(
      key: ValueKey('calendar-row-$id'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => context.push(detailLocation(SourceTarget(entry.ref))),
      child: Row(
        children: [
          Opacity(
            opacity: 0.5,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 64,
                height: 36,
                child: CalendarArtwork(entry: entry),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  entry.calendarTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: TimelineLayout.titleLine / 13,
                    fontWeight: FontWeight.w600,
                    color: palette.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: TimelineLayout.subtitleLine *
                      MediaQuery.textScalerOf(context).scale(1),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          context.l10n.calendarNumbering(entry),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            height: TimelineLayout.subtitleLine / 11,
                            color: palette.textSecondary,
                          ),
                        ),
                      ),
                      if (!entry.isPlayable) ...[
                        const SizedBox(width: 6),
                        _StatusChip(
                          key: ValueKey(_isFuture
                              ? 'calendar-upcoming-$id'
                              : 'calendar-absent-$id'),
                          label: _isFuture ? 'Upcoming' : 'Not in library',
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: palette.textDisabled,
        ),
      ),
    );
  }
}
