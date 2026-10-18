/// The featured title at the top of a source's home.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/focus/focus_reveal_section.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/sources/media_source.dart' show ArtworkRequest;
import '../../../core/sources/source.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/palette.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/glass/glass_badge.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/primary_play_button.dart';
import '../../widgets/shell_rail_inset.dart';
import '../../widgets/source_artwork.dart';
import '../detail/detail_links.dart';
import '../detail/play_item.dart';
import 'source_home_hero_backdrop.dart';

class SourceHomeHero extends ConsumerWidget {
  const SourceHomeHero({
    super.key,
    required this.sourceId,
    required this.item,
    this.bleedTop = 0,
  });

  final SourceId sourceId;
  final ItemSummary item;

  /// How far the backdrop runs above the hero's own box, for a screen that
  /// puts space between the window top and the hero. Zero where something
  /// else (a banner) sits there.
  final double bleedTop;

  /// Identifies the backdrop layer.
  static const backdropKey = Key('source-home-hero-backdrop');

  static const _wideGap = 36.0;
  static const _maxTextWidth = 560.0;

  /// The poster card's size when the hero is laid out wide.
  static const posterSize = Size(248, 360);

  /// The stacked layout's poster width: 60% of the screen, capped so a
  /// window just under the wide breakpoint does not get a giant poster.
  static double narrowPosterWidth(BuildContext context) =>
      math.min(MediaQuery.sizeOf(context).width * 0.6, 320);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
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

    final glass = GlassStyle.of(context);
    final infoColumn = Column(
      crossAxisAlignment:
          wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (chips.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final c in chips) _HeroChip(c, grouped: glass)],
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
              color: palette.textPrimary.withValues(alpha: 0.78),
            ),
          ),
        ],
        const SizedBox(height: 20),
        _HeroActions(
          wide: wide,
          grouped: glass,
          onPlay: () => playItem(context, ref, item.ref),
          secondaryLabel: isEpisode ? 'All episodes' : 'More info',
          onSecondary: open,
        ),
      ],
    );

    // One backdrop pass shared by the chips, Play and the secondary action.
    final info = glass ? BackdropGroup(child: infoColumn) : infoColumn;

    // UP from the first rail lands on the hero's buttons, which sit at its
    // bottom. On a television this reveals the whole hero, not just the button.
    final topPad = MediaQuery.paddingOf(context).top + 24;
    final backdrop = request == null
        ? null
        : _backdrop(context, request,
            wide: wide, padding: padding, top: topPad);
    return FocusRevealSection(
      child: Stack(
        clipBehavior: Clip.none,
        // Passthrough: the content sizes the hero exactly as it did before
        // the backdrop, which is only ever a background layer.
        fit: StackFit.passthrough,
        children: [
          if (backdrop != null) backdrop,
          _content(
            context,
            wide: wide,
            padding: padding,
            top: topPad,
            poster: poster,
            info: info,
          ),
        ],
      ),
    );
  }

  /// The artwork layer, positioned relative to the hero's own box: under the
  /// rail and up to the window top on wide layouts, behind the poster on
  /// stacked ones.
  Widget _backdrop(
    BuildContext context,
    ArtworkRequest request, {
    required bool wide,
    required double padding,
    required double top,
  }) {
    // The page is inset by the rail and the hero's own box starts at the
    // column; the wide backdrop reaches back left under the rail.
    final inset = wide ? ShellRailInset.of(context) : 0.0;
    final layer = HomeHeroBackdrop(
      key: backdropKey,
      request: request,
      wide: wide,
      inset: inset,
      padding: padding,
      posterSize: posterSize,
      gap: _wideGap,
      maxTextWidth: _maxTextWidth,
    );
    if (wide) {
      return Positioned(
        left: -inset,
        right: 0,
        top: -bleedTop,
        bottom: 0,
        child: layer,
      );
    }
    final posterHeight =
        narrowPosterWidth(context) * posterSize.height / posterSize.width;
    return Positioned(
      left: 0,
      right: 0,
      top: -bleedTop,
      height: bleedTop +
          top +
          posterHeight +
          HomeHeroBackdropTokens.narrowPosterGap,
      child: layer,
    );
  }

  Widget _content(
    BuildContext context, {
    required bool wide,
    required double padding,
    required double top,
    required Widget poster,
    required Widget info,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        padding,
        top,
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
                const SizedBox(width: _wideGap),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: _maxTextWidth),
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
                const SizedBox(
                  height: HomeHeroBackdropTokens.narrowPosterGap,
                ),
                info,
              ],
            ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip(this.label, {required this.grouped});

  final String label;
  final bool grouped;

  @override
  Widget build(BuildContext context) => GlassBadge(
        grouped: grouped,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        fallbackDecoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppTheme.radiusChip),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      );
}

class _HeroActions extends StatelessWidget {
  const _HeroActions({
    required this.wide,
    required this.grouped,
    required this.onPlay,
    required this.secondaryLabel,
    required this.onSecondary,
  });

  final bool wide;
  final bool grouped;
  final VoidCallback onPlay;
  final String secondaryLabel;
  final VoidCallback onSecondary;

  static const _height = 52.0;

  @override
  Widget build(BuildContext context) {
    final glass = GlassStyle.of(context);
    final Widget play = glass
        ? PrimaryPlayButton(
            key: const Key('source-home-hero-play'),
            onPressed: onPlay,
            grouped: grouped,
          )
        : FilledButton.icon(
            key: const Key('source-home-hero-play'),
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, _height)),
          );
    Widget secondary = GlassButton(
      buttonKey: const Key('source-home-hero-more'),
      label: secondaryLabel,
      onPressed: onSecondary,
      grouped: grouped,
      height: glass ? PrimaryPlayButton.height : _height,
    );
    if (glass) {
      // Play carries a ring gap around its pill; match it so both pills share
      // a height and baseline.
      secondary = Padding(
        padding: const EdgeInsets.all(PrimaryPlayButton.ringGap),
        child: secondary,
      );
    }
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
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      color: palette.surface,
      child: Icon(
        Icons.movie_rounded,
        size: 64,
        color: palette.textSecondary,
      ),
    );
  }
}
