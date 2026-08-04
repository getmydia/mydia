import 'package:flutter/material.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/continue_watching_item.dart';
import '../../domain/models/recently_added_item.dart';
import '../../domain/models/up_next_item.dart';
import 'media_card.dart';

class ContentRail extends StatefulWidget {
  final String title;
  final List<dynamic> items;
  final bool showProgress;
  final bool showEpisodeInfo;
  final Function(String id, String type)? onItemTap;
  final VoidCallback? onSeeAllTap;

  /// Called instead of [onItemTap] for cards that should start playback
  /// directly. Passes the item itself, because choosing a file needs the
  /// item's files and progress, which an (id, type) pair cannot carry.
  final void Function(Object item)? onItemActivate;

  const ContentRail({
    super.key,
    required this.title,
    required this.items,
    this.showProgress = false,
    this.showEpisodeInfo = false,
    this.onItemTap,
    this.onSeeAllTap,
    this.onItemActivate,
  });

  @override
  State<ContentRail> createState() => _ContentRailState();
}

class _ContentRailState extends State<ContentRail> {
  final ScrollController _scrollController = ScrollController();
  bool _showLeftFade = false;
  bool _showRightFade = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateFadeState);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateFadeState);
    _scrollController.dispose();
    super.dispose();
  }

  void _updateFadeState() {
    final showLeft = _scrollController.offset > 10;
    final showRight = _scrollController.offset <
        _scrollController.position.maxScrollExtent - 10;

    if (showLeft != _showLeftFade || showRight != _showRightFade) {
      setState(() {
        _showLeftFade = showLeft;
        _showRightFade = showRight;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const SizedBox.shrink();
    }

    final railHeight = Breakpoints.getRailHeight(context);
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);
    final isDesktop = Breakpoints.isDesktop(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: EdgeInsets.fromLTRB(horizontalPadding, isDesktop ? 32 : 24,
              horizontalPadding, isDesktop ? 20 : 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.3,
                    ),
              ),
              if (widget.onSeeAllTap != null)
                TextButton.icon(
                  onPressed: widget.onSeeAllTap,
                  icon: const Text('See All'),
                  label: const Icon(Icons.chevron_right_rounded, size: 18),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
            ],
          ),
        ),

        // Scrollable content with fade edges
        SizedBox(
          height: railHeight,
          child: Stack(
            children: [
              // Main scrollable list
              ListView.builder(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                itemCount: widget.items.length,
                itemBuilder: (context, index) {
                  final item = widget.items[index];
                  return Padding(
                    key: _keyFor(item, index),
                    padding: EdgeInsets.only(
                      right: index < widget.items.length - 1 ? cardSpacing : 0,
                    ),
                    child: _buildCard(context, item),
                  );
                },
              ),

              // Left fade gradient
              if (_showLeftFade)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
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

              // Right fade gradient
              if (_showRightFade)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
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
        ),
      ],
    );
  }

  /// Stable, id-based key for a rail item so the [ListView.builder] cards keep
  /// their identity as the list updates (player key convention). Falls back to
  /// an index key for unrecognized item types.
  Key _keyFor(dynamic item, int index) {
    if (item is ContinueWatchingItem) return ValueKey('cw-${item.id}');
    if (item is RecentlyAddedItem) return ValueKey('ra-${item.id}');
    if (item is UpNextItem) return ValueKey('un-${item.episode.id}');
    return ValueKey('rail-$index');
  }

  Widget _buildCard(BuildContext context, dynamic item) {
    final cardSize = Breakpoints.getCardSize(context);

    if (item is ContinueWatchingItem) {
      return MediaCard(
        posterUrl: item.posterUrl,
        title: item.title,
        subtitle: item.showTitle,
        progressPercentage: item.progress?.percentage,
        width: cardSize.width,
        height: cardSize.height,
        onTap: () => widget.onItemActivate != null
            ? widget.onItemActivate!(item)
            : widget.onItemTap?.call(item.id, item.type),
      );
    } else if (item is RecentlyAddedItem) {
      return MediaCard(
        posterUrl: item.posterUrl,
        title: item.title,
        subtitle: item.year?.toString(),
        width: cardSize.width,
        height: cardSize.height,
        onTap: () => widget.onItemTap?.call(item.id, item.type),
      );
    } else if (item is UpNextItem) {
      return MediaCard(
        posterUrl: item.posterUrl,
        title: item.show.title,
        subtitle: item.episode.episodeCode,
        width: cardSize.width,
        height: cardSize.height,
        onTap: () => widget.onItemActivate != null
            ? widget.onItemActivate!(item)
            : widget.onItemTap?.call(item.episode.id, 'episode'),
      );
    }
    return const SizedBox.shrink();
  }
}
