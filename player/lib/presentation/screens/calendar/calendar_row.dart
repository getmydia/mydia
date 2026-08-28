// Resume: the player never trusts route absence as "no progress". Every
// entry point into `PlayerScreen` independently queries `progress {
// positionSeconds durationSeconds lastWatchedAt }` off `MovieDetail` /
// `EpisodeDetail` in `_fetchProgressAndEpisodes`, and `resolveResumePlan`
// (`core/player/resume_plan.dart`) offers a resume dialog through
// `shouldOfferResume` whenever that saved position clears the existing
// thresholds. The route's `resume` query parameter only lets a caller that
// already asked the question (Continue Watching) skip that dialog and jump
// straight to the saved position; its absence does not mean "start from
// zero", it means "let the player ask". The calendar carries no progress, so
// the consequence is simply that every calendar-initiated playback goes
// through the normal resume prompt instead of bypassing it, exactly like
// opening the same episode from its own detail screen would.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/models/calendar_entry.dart';
import '../../widgets/smart_play_button.dart';

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

  final CalendarEntry entry;

  /// Injected rather than read from the clock so tests are deterministic.
  final DateTime today;

  bool get _isFuture => entry.day.isAfter(
        DateTime(today.year, today.month, today.day),
      );

  String get _subtitle {
    if (entry.kind == CalendarEntryKind.movie) return 'Movie';

    final season = (entry.seasonNumber ?? 0).toString().padLeft(2, '0');
    final episode = (entry.episodeNumber ?? 0).toString().padLeft(2, '0');
    final numbering = 'S${season}E$episode';

    return entry.title.isEmpty ? numbering : '$numbering · ${entry.title}';
  }

  void _openDetail(BuildContext context) {
    if (entry.kind == CalendarEntryKind.movie) {
      context.push('/movie/${entry.mediaItemId}');
    } else {
      context.push('/episode/${entry.id}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dimmed = !entry.isPlayable;

    return InkWell(
      key: ValueKey('calendar-row-${entry.id}'),
      onTap: () => _openDetail(context),
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
                    entry.kind == CalendarEntryKind.movie
                        ? entry.title
                        : entry.mediaItemTitle,
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
      return SmartPlayButton(
        key: ValueKey('calendar-play-${entry.id}'),
        files: entry.files,
        onFileSelected: (file) => context.push(
          playerRouteForCalendar(entry, fileId: file.id),
        ),
      );
    }

    if (_isFuture) {
      return _StatusChip(
        key: ValueKey('calendar-upcoming-${entry.id}'),
        label: 'Upcoming',
      );
    }

    return _StatusChip(
      key: ValueKey('calendar-absent-${entry.id}'),
      label: 'Not in library',
    );
  }
}

/// The player route for one calendar entry.
///
/// Kept beside the row rather than inlined so the shape stays in one place
/// if the player screen ever reads another query parameter. Mirrors
/// `playerRouteForContinueWatching` in `home_screen.dart`, minus the resume
/// suffix: the calendar has no saved progress of its own to pass, so the
/// player is left to discover it (see the resume note at the top of this
/// file). `fileId` is required because the player route renders an error
/// screen without one.
String playerRouteForCalendar(CalendarEntry entry, {required String fileId}) {
  final title = Uri.encodeComponent(
    entry.kind == CalendarEntryKind.movie ? entry.title : entry.mediaItemTitle,
  );

  if (entry.kind == CalendarEntryKind.movie) {
    return '/player/movie/${entry.mediaItemId}?fileId=$fileId&title=$title';
  }

  final showId = entry.mediaItemId;
  final seasonNumber = entry.seasonNumber;

  return '/player/episode/${entry.id}'
      '?fileId=$fileId'
      '&title=$title'
      '&showId=$showId'
      '${seasonNumber != null ? '&seasonNumber=$seasonNumber' : ''}';
}

class _Poster extends StatelessWidget {
  const _Poster({required this.entry, required this.dimmed});

  final CalendarEntry entry;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final url = entry.artwork?.posterUrl;

    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 38,
          height: 56,
          child: url == null
              ? const ColoredBox(color: AppColors.surfaceVariant)
              : CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  cacheManager: PosterCacheManager(),
                  placeholder: (_, __) =>
                      const ColoredBox(color: AppColors.surfaceVariant),
                  errorWidget: (_, __, ___) =>
                      const ColoredBox(color: AppColors.surfaceVariant),
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
