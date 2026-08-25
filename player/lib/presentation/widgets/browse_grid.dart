import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../core/layout/breakpoints.dart';
import '../../core/layout/dock_insets.dart';
import '../../core/player/input_capabilities.dart';

/// The poster grid shared by every browse screen that shows media.
///
/// Exists because five screens hand-rolled the same delegate and three of the
/// copies had drifted: one duplicated `libraryCrossAxisCount` verbatim as a
/// private helper, and four hardcoded a 100px top padding that was tuned for
/// a mobile toolbar and became dead space on desktop.
///
/// Collections deliberately does not use this. `_CollectionCard` is a
/// different shape (aspect 0.85, its own column table), which is a real
/// design difference rather than drift, so that screen takes `BrowseScaffold`
/// alone and keeps its own grid.
class BrowseGrid extends StatelessWidget {
  /// How far past the viewport the grid keeps cells built.
  ///
  /// Same reasoning as the rails: focus traversal cannot reach a widget that
  /// has not been built, and `GridView.builder` is as lazy as
  /// `ListView.builder`. Two viewport heights, applied only in the
  /// directional tier.
  static const double _directionalCacheExtent = 1600;

  const BrowseGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.scrollTopPadding,
    this.controller,
  });

  final int itemCount;
  final Widget? Function(BuildContext context, int index) itemBuilder;

  /// Top padding that clears the glass bar, from `BrowseScaffold`'s body
  /// builder. Never computed here: only the scaffold knows the bar's height.
  final double scrollTopPadding;

  /// Supplied by screens that paginate on scroll.
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);
    final bottomPadding = DockInsets.bottomOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          controller: controller,
          scrollCacheExtent: InputCapabilities.directionalPrimary
              ? const ScrollCacheExtent.pixels(_directionalCacheExtent)
              : null,
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            scrollTopPadding,
            horizontalPadding,
            bottomPadding,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: libraryCrossAxisCount(constraints.maxWidth),
            childAspectRatio: 0.58,
            crossAxisSpacing: cardSpacing,
            mainAxisSpacing: cardSpacing + 4,
          ),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}
