import 'package:flutter/material.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/episode.dart';
import 'episode_rail_card.dart';

/// A horizontal rail of [EpisodeRailCard]s with edge-fade gradients and
/// responsive spacing.
///
/// Mirrors `ContentRail`'s scroll mechanics — a [ScrollController] driving
/// left/right fade visibility and a horizontal [ListView.builder] sized via
/// [Breakpoints] — but renders landscape episode cards instead of portrait
/// posters. The fade/scroll shell is deliberately duplicated rather than
/// abstracted; extracting a shared shell is deferred follow-up.
class EpisodeRail extends StatefulWidget {
  final List<Episode> episodes;
  final String showTitle;
  final String? showId;
  final String? showPosterUrl;

  /// Invoked when a playable episode card is tapped.
  final ValueChanged<Episode>? onEpisodeTap;

  const EpisodeRail({
    super.key,
    required this.episodes,
    required this.showTitle,
    this.showId,
    this.showPosterUrl,
    this.onEpisodeTap,
  });

  @override
  State<EpisodeRail> createState() => _EpisodeRailState();
}

class _EpisodeRailState extends State<EpisodeRail> {
  final ScrollController _scrollController = ScrollController();

  // Both fades start hidden and are turned on once layout reports how far the
  // rail can actually scroll. Assuming a right fade up front would leave one
  // stranded over a rail whose episodes already fit on screen.
  bool _showLeftFade = false;
  bool _showRightFade = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateFadeState);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Runs once on mount and again whenever the width changes (rotation,
    // resize, window drag), both of which change how far the rail can scroll.
    _scheduleFadeUpdate();
  }

  @override
  void didUpdateWidget(covariant EpisodeRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episodes.length != widget.episodes.length) {
      _scheduleFadeUpdate();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateFadeState);
    _scrollController.dispose();
    super.dispose();
  }

  /// Scroll extent is only known once the list has been laid out, so anything
  /// that changes it has to defer the recompute to the end of the frame.
  void _scheduleFadeUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateFadeState());
  }

  void _updateFadeState() {
    if (!mounted || !_scrollController.hasClients) return;

    final position = _scrollController.position;
    final showLeft = position.pixels > 10;
    final showRight = position.pixels < position.maxScrollExtent - 10;

    if (showLeft != _showLeftFade || showRight != _showRightFade) {
      setState(() {
        _showLeftFade = showLeft;
        _showRightFade = showRight;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.episodes.isEmpty) {
      return const SizedBox.shrink();
    }

    final railHeight = Breakpoints.getEpisodeRailHeight(context);
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);

    return SizedBox(
      height: railHeight,
      child: Stack(
        children: [
          // Main scrollable list of episode cards.
          ListView.builder(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            itemCount: widget.episodes.length,
            itemBuilder: (context, index) {
              final episode = widget.episodes[index];
              return Padding(
                key: ValueKey(episode.id),
                padding: EdgeInsets.only(
                  right: index < widget.episodes.length - 1 ? cardSpacing : 0,
                ),
                child: EpisodeRailCard(
                  episode: episode,
                  showTitle: widget.showTitle,
                  showId: widget.showId,
                  showPosterUrl: widget.showPosterUrl,
                  onTap: episode.hasFile && widget.onEpisodeTap != null
                      ? () => widget.onEpisodeTap!(episode)
                      : null,
                ),
              );
            },
          ),

          // Left fade gradient.
          if (_showLeftFade)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('episode-rail-left-fade'),
                  width: 40,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        AppColors.background,
                        AppColors.background.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Right fade gradient.
          if (_showRightFade)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('episode-rail-right-fade'),
                  width: 40,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerRight,
                      end: Alignment.centerLeft,
                      colors: [
                        AppColors.background,
                        AppColors.background.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
