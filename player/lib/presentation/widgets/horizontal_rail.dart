import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../../core/layout/breakpoints.dart';
import '../../core/player/input_capabilities.dart';
import '../../core/theme/colors.dart';
import 'horizontal_wheel_scroll.dart';
import 'rail_focus_scroller.dart';

/// The scroll-and-fade shell shared by the app's horizontal rails.
///
/// Owns the [ScrollController], the left/right edge-fade visibility, and the
/// post-frame recompute that has to run whenever the scrollable extent
/// changes. Callers supply the item count, an item builder, and the rail
/// height; inter-card spacing and horizontal padding come from [Breakpoints]
/// so every rail lines up with every other.
///
/// Fade keys are caller-supplied so a screen showing several rails keeps each
/// one's fades individually assertable in tests.
class HorizontalRail extends StatefulWidget {
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final double height;
  final Key leftFadeKey;
  final Key rightFadeKey;

  const HorizontalRail({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.height,
    required this.leftFadeKey,
    required this.rightFadeKey,
  });

  @override
  State<HorizontalRail> createState() => _HorizontalRailState();
}

class _HorizontalRailState extends State<HorizontalRail> {
  /// How far past the viewport the list keeps items built.
  ///
  /// Same reasoning as `ContentRail`: focus traversal can only reach a
  /// widget that exists, and `ListView.builder`'s 250px default is narrower
  /// than a single episode still. Two viewport widths guarantee at least one
  /// built item past each edge, applied only in the directional tier.
  static const double _directionalCacheExtent = 2400;

  final ScrollController _scrollController = ScrollController();

  // Both fades start hidden and are turned on once layout reports how far the
  // rail can actually scroll. Assuming a right fade up front would leave one
  // stranded over a rail whose items already fit on screen.
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
  void didUpdateWidget(covariant HorizontalRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount) {
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
    if (widget.itemCount == 0) {
      return const SizedBox.shrink();
    }

    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);

    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          // The wrapper is what makes a plain mouse wheel move the rail; the
          // controller stays owned here because the edge fades listen to it.
          HorizontalWheelScroll(
            controller: _scrollController,
            builder: (context, controller) => ListView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              scrollCacheExtent: InputCapabilities.directionalPrimary
                  ? const ScrollCacheExtent.pixels(_directionalCacheExtent)
                  : null,
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              itemCount: widget.itemCount,
              itemBuilder: (context, index) {
                return Padding(
                  padding: EdgeInsets.only(
                    right: index < widget.itemCount - 1 ? cardSpacing : 0,
                  ),
                  child: RailFocusScroller(
                    child: widget.itemBuilder(context, index),
                  ),
                );
              },
            ),
          ),
          if (_showLeftFade) _buildFade(widget.leftFadeKey, atStart: true),
          if (_showRightFade) _buildFade(widget.rightFadeKey, atStart: false),
        ],
      ),
    );
  }

  Widget _buildFade(Key key, {required bool atStart}) {
    return Positioned(
      left: atStart ? 0 : null,
      right: atStart ? null : 0,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          key: key,
          width: 40,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: atStart ? Alignment.centerLeft : Alignment.centerRight,
              end: atStart ? Alignment.centerRight : Alignment.centerLeft,
              colors: [
                AppColors.background,
                AppColors.background.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
