// Resume: the player never trusts route absence as "no progress". The source
// player route asks the source for the saved position of the item it plays,
// and offers the resume dialog when that position clears the existing
// thresholds. The calendar carries no progress, so every calendar-initiated
// playback goes through the normal resume prompt, exactly like opening the
// same episode from its own detail screen would.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/play_button.dart';
import '../../widgets/source_artwork.dart';
import '../detail/detail_links.dart';
import 'calendar_dates.dart';

/// One dated entry on the calendar, rendered as a single row.
///
/// The row body opens the detail screen; the trailing control plays. Two
/// separate targets, deliberately: a mistap on the body cannot start
/// playback, and on Android TV a list of single-target rows gives the D-pad
/// nothing to do horizontally, while this one gives it the play control to
/// land on.
class CalendarRow extends ConsumerWidget {
  const CalendarRow({
    super.key,
    required this.entry,
    required this.today,
  });

  final ItemSummary entry;

  /// Injected rather than read from the clock so tests are deterministic.
  final DateTime today;

  String get _id => entry.ref.externalId;

  bool get _isMovie => entry.ref.kind == ItemKind.movie;

  bool get _isFuture {
    final day = entry.day;
    return day != null && day.isAfter(truncateToDay(today));
  }

  String get _subtitle {
    if (_isMovie) return 'Movie';

    final season = (entry.parentIndex ?? 0).toString().padLeft(2, '0');
    final episode = (entry.index ?? 0).toString().padLeft(2, '0');
    final numbering = 'S${season}E$episode';

    return entry.title.isEmpty ? numbering : '$numbering · ${entry.title}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dimmed = !entry.isPlayable;

    return InkWell(
      key: ValueKey('calendar-row-$_id'),
      onTap: () => context.push(detailLocation(SourceTarget(entry.ref))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            _Poster(entry: entry, dimmed: dimmed),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _isMovie ? entry.title : entry.showTitle ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: dimmed
                          ? AppColors.textDisabled
                          : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: dimmed
                              ? AppColors.textDisabled
                              : AppColors.textSecondary,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _trailing(context),
          ],
        ),
      ),
    );
  }

  Widget _trailing(BuildContext context) {
    if (entry.isPlayable) {
      return PlayButton(
        key: ValueKey('calendar-play-$_id'),
        onPressed: () => context.push(sourcePlayerLocation(
          entry.ref,
          fileId: entry.defaultVersionId,
          title: entry.title,
        )),
      );
    }

    if (_isFuture) {
      return _StatusChip(
        key: ValueKey('calendar-upcoming-$_id'),
        label: 'Upcoming',
      );
    }

    return _StatusChip(
      key: ValueKey('calendar-absent-$_id'),
      label: 'Not in library',
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.entry, required this.dimmed});

  final ItemSummary entry;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    const fallback = ColoredBox(color: AppColors.surfaceVariant);
    final poster = entry.poster;

    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 38,
          height: 56,
          child: poster == null
              ? fallback
              : SourceArtworkImage(
                  sourceId: entry.ref.sourceId,
                  art: poster,
                  fallback: fallback,
                ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 10, color: AppColors.textDisabled),
      ),
    );
  }
}
