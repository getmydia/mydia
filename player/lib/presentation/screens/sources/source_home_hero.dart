/// The featured title at the top of a source's home.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/focus/focus_reveal_section.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/sources/source.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/source_artwork.dart';
import '../detail/detail_links.dart';

class SourceHomeHero extends ConsumerWidget {
  const SourceHomeHero({super.key, required this.sourceId, required this.item});

  final SourceId sourceId;
  final ItemSummary item;

  /// The poster card's size when the hero is laid out wide.
  static const posterSize = Size(248, 360);

  /// The stacked layout's poster width: 60% of the screen, capped so a
  /// window just under the wide breakpoint does not get a giant poster.
  static double narrowPosterWidth(BuildContext context) =>
      math.min(MediaQuery.sizeOf(context).width * 0.6, 320);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final art = item.backdrop ?? item.poster;
    final request = art == null
        ? null
        : ref
            .watch(sourceArtworkProvider((
              sourceId: sourceId,
              art: art,
              width: SourceBackdrop.artworkWidth,
            )))
            .value;
    // The shell's ambient backdrop and tint follow the hero's artwork,
    // credentials included.
    publishBackdropSource(
      ref,
      request == null
          ? BackdropSource.none
          : BackdropSource(
              imageUrl: request.url,
              id: request.cacheKey,
              headers: request.headers,
              cacheKey: request.cacheKey,
            ),
    );

    final wide = Breakpoints.isDesktop(context);
    final padding = Breakpoints.getHorizontalPadding(context);
    final textTheme = Theme.of(context).textTheme;
    void open() => context.push(sourceItemLocation(item.ref));
    final isEpisode = item.showTitle != null;
    final chips = [
      if (item.subtitle case final s?) s,
      if (item.year case final y?) '$y',
    ];

    final poster = ClipRRect(
      key: const Key('source-home-hero-poster'),
      borderRadius: BorderRadius.circular(AppTheme.radiusHeroPoster),
      child: item.poster == null
          ? const _HeroFallback()
          : SourceArtworkImage(
              sourceId: sourceId,
              art: item.poster!,
              fallback: const _HeroFallback(),
            ),
    );

    final info = Column(
      crossAxisAlignment:
          wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (chips.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final c in chips) _HeroChip(c)],
          ),
          const SizedBox(height: 14),
        ],
        Text(
          isEpisode ? item.showTitle! : item.title,
          style: textTheme.displayLarge?.copyWith(
            fontSize: wide ? 48 : 30,
            letterSpacing: -1.2,
            height: 1.0,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: wide ? TextAlign.start : TextAlign.center,
        ),
        if (item.overview case final overview?) ...[
          const SizedBox(height: 12),
          Text(
            overview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: textTheme.bodyLarge?.copyWith(
              color: AppColors.textPrimary.withValues(alpha: 0.78),
            ),
          ),
        ],
        const SizedBox(height: 20),
        _HeroActions(
          wide: wide,
          onPlay: open,
          secondaryLabel: isEpisode ? 'All episodes' : 'More info',
          onSecondary: open,
        ),
      ],
    );

    // UP from the first rail lands on the hero's buttons, which sit at its
    // bottom. On a television this reveals the whole hero, not just the button.
    return FocusRevealSection(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          padding,
          MediaQuery.paddingOf(context).top + 24,
          padding,
          32,
        ),
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  DecoratedBox(
                    decoration: const BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x73000000),
                          blurRadius: 60,
                          offset: Offset(0, 30),
                        ),
                      ],
                    ),
                    child: SizedBox(
                      width: posterSize.width,
                      height: posterSize.height,
                      child: poster,
                    ),
                  ),
                  const SizedBox(width: 36),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: info,
                      ),
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  // 60% of the screen, not of the padded column.
                  SizedBox(
                    width: narrowPosterWidth(context),
                    child: AspectRatio(
                      aspectRatio: posterSize.width / posterSize.height,
                      child: poster,
                    ),
                  ),
                  const SizedBox(height: 20),
                  info,
                ],
              ),
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppTheme.radiusChip),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      );
}

class _HeroActions extends StatelessWidget {
  const _HeroActions({
    required this.wide,
    required this.onPlay,
    required this.secondaryLabel,
    required this.onSecondary,
  });

  final bool wide;
  final VoidCallback onPlay;
  final String secondaryLabel;
  final VoidCallback onSecondary;

  static const _height = 52.0;

  @override
  Widget build(BuildContext context) {
    final play = FilledButton.icon(
      key: const Key('source-home-hero-play'),
      onPressed: onPlay,
      icon: const Icon(Icons.play_arrow_rounded),
      label: const Text('Play'),
      style: FilledButton.styleFrom(minimumSize: const Size(0, _height)),
    );
    final secondary = OutlinedButton(
      key: const Key('source-home-hero-more'),
      onPressed: onSecondary,
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, _height)),
      child: Text(secondaryLabel),
    );
    if (wide) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [play, const SizedBox(width: 12), secondary],
      );
    }
    return Column(
      children: [
        SizedBox(width: double.infinity, child: play),
        const SizedBox(height: 10),
        SizedBox(width: double.infinity, child: secondary),
      ],
    );
  }
}

class _HeroFallback extends StatelessWidget {
  const _HeroFallback();

  @override
  Widget build(BuildContext context) => Container(
        color: AppColors.surface,
        child: const Icon(
          Icons.movie_rounded,
          size: 64,
          color: AppColors.textSecondary,
        ),
      );
}
