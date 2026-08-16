import 'package:flutter/material.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/continue_watching_item.dart';
import '../../domain/models/recently_added_item.dart';
import '../../domain/models/up_next_item.dart';
import '../../domain/models/watch_status.dart';
import 'media_card.dart';
import 'media_context_menu.dart';

/// Shared by the chevron rotation and the height change so a collapsible rail
/// opens as one motion.
const _disclosureDuration = Duration(milliseconds: 220);

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

  /// Turns the header into a disclosure and starts the rail collapsed, so only
  /// the title line is drawn until it is tapped. For rails that are supporting
  /// context rather than the reason the page was opened, an always-open strip
  /// of posters competes with the content it sits beside.
  final bool collapsible;

  const ContentRail({
    super.key,
    required this.title,
    required this.items,
    this.showProgress = false,
    this.showEpisodeInfo = false,
    this.onItemTap,
    this.onSeeAllTap,
    this.onItemActivate,
    this.collapsible = false,
  });

  /// Test/lookup handle for the disclosure chevron (player key convention).
  static const disclosureKey = ValueKey('content-rail-disclosure');

  @override
  State<ContentRail> createState() => _ContentRailState();
}

class _ContentRailState extends State<ContentRail> {
  final ScrollController _scrollController = ScrollController();
  bool _showLeftFade = false;
  bool _showRightFade = true;
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = !widget.collapsible;
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
        _buildHeader(context, horizontalPadding, isDesktop),

        // Scrollable content with fade edges. A collapsed rail builds none of
        // it, so a hidden rail costs no cards and no poster fetches.
        AnimatedSize(
          duration: _disclosureDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? SizedBox(
                  height: railHeight,
                  child: _buildRailBody(horizontalPadding, cardSpacing),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }

  /// The header line. When [ContentRail.collapsible] it doubles as the
  /// disclosure control for the strip below it.
  Widget _buildHeader(
    BuildContext context,
    double horizontalPadding,
    bool isDesktop,
  ) {
    // Closed, the title sits directly above whatever follows it, so it keeps
    // only enough room to read as its own line rather than the gap that an
    // open rail needs above its posters.
    final bottomPadding =
        _expanded ? (isDesktop ? 20.0 : 16.0) : (isDesktop ? 10.0 : 8.0);

    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        isDesktop ? 32 : 24,
        horizontalPadding,
        bottomPadding,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              widget.title,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.3,
                  ),
            ),
          ),
          if (widget.collapsible)
            AnimatedRotation(
              key: ContentRail.disclosureKey,
              turns: _expanded ? 0.5 : 0,
              duration: _disclosureDuration,
              curve: Curves.easeOutCubic,
              child: const Icon(
                Icons.expand_more_rounded,
                size: 26,
                color: AppColors.textSecondary,
              ),
            )
          else if (widget.onSeeAllTap != null)
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
    );

    if (!widget.collapsible) return header;

    return Semantics(
      button: true,
      expanded: _expanded,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: header,
      ),
    );
  }

  Widget _buildRailBody(double horizontalPadding, double cardSpacing) {
    return Stack(
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
      final target = MediaContextTarget(
        id: item.id,
        type: item.type,
        showId: item.showId,
        hasFile: item.files.isNotEmpty,
        tapPlays: widget.onItemActivate != null,
      );
      return MediaCard(
        posterUrl: item.posterUrl,
        title: item.title,
        subtitle: item.railSubtitle,
        // Derived here for the same reason the Continue Watching screen
        // derives it: `ContinueWatchingItem` carries a `Progress` row and no
        // `watchStatus`, and adapting it puts this rail on the shared
        // rendering rule instead of the legacy percentage prop.
        watchStatus: item.progress == null
            ? null
            : WatchStatus.fromProgress(item.progress!),
        width: cardSize.width,
        height: cardSize.height,
        action: _actionFor(target),
        onTap: () => widget.onItemActivate != null
            ? widget.onItemActivate!(item)
            : widget.onItemTap?.call(item.id, item.type),
        onContextMenu: (cardContext) => _openMenu(cardContext, target, item),
      );
    } else if (item is RecentlyAddedItem) {
      final target = MediaContextTarget(id: item.id, type: item.type);
      return MediaCard(
        posterUrl: item.posterUrl,
        title: item.title,
        subtitle: item.newContentLabel ?? item.year?.toString(),
        watchStatus: item.watchStatus,
        width: cardSize.width,
        height: cardSize.height,
        action: _actionFor(target),
        onTap: () => widget.onItemTap?.call(item.id, item.type),
        onContextMenu: (cardContext) => _openMenu(cardContext, target, item),
      );
    } else if (item is UpNextItem) {
      final target = MediaContextTarget(
        id: item.episode.id,
        type: 'episode',
        showId: item.show.id,
        hasFile: item.episode.hasFile,
        tapPlays: widget.onItemActivate != null,
      );
      return MediaCard(
        posterUrl: item.posterUrl,
        title: item.show.title,
        subtitle: item.episode.episodeCode,
        watchStatus: item.episode.progress == null
            ? null
            : WatchStatus.fromProgress(item.episode.progress!),
        width: cardSize.width,
        height: cardSize.height,
        action: _actionFor(target),
        onTap: () => widget.onItemActivate != null
            ? widget.onItemActivate!(item)
            : widget.onItemTap?.call(item.episode.id, 'episode'),
        onContextMenu: (cardContext) => _openMenu(cardContext, target, item),
      );
    }
    return const SizedBox.shrink();
  }

  /// A card promises playback exactly when its tap delivers it, which is when
  /// this rail was given an activate handler and the target is playable.
  MediaCardAction _actionFor(MediaContextTarget target) =>
      target.tapPlays && target.hasFile
          ? MediaCardAction.play
          : MediaCardAction.open;

  /// The rail owns the menu rather than forwarding it to the screen: it
  /// already knows how to turn each item type into a target, and it already
  /// holds the play handler the menu's Play entry needs.
  void _openMenu(
    BuildContext cardContext,
    MediaContextTarget target,
    Object item,
  ) {
    showMediaContextMenu(
      cardContext,
      target: target,
      onPlay: () => widget.onItemActivate?.call(item),
    );
  }
}
