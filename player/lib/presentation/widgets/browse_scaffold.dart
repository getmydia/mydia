import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/graphql/watch/query_key.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import 'ambient_backdrop_provider.dart';
import 'app_shell.dart';
import 'cast_actions.dart';
import 'cast_button.dart';
import 'freshness_header.dart';
import 'glass_surface.dart';

/// Builds a screen's scrollable body, given the top padding it must reserve
/// so its first item lands below the glass bar rather than behind it.
typedef BrowseBodyBuilder = Widget Function(
  BuildContext context,
  double scrollTopPadding,
);

/// The single owner of the browse-screen page-chrome contract.
///
/// Before this widget, the contract lived only in `LibraryScreen` and six
/// other screens copied fragments of it three different ways. Two of those
/// fragments were load-bearing and routinely went missing:
///
///  * the glass bar was suppressed entirely on desktop, which left those
///    screens with no title anywhere and made `freshnessTopInset` return 0,
///    so their grids either sat 8px from the top edge or cleared a bar that
///    was not there with a hardcoded 100px of dead space;
///  * `FreshnessHeader` was mounted as a `Column` sibling, so it was charged
///    as layout height and every background refetch shoved the whole grid
///    down by about 58px. `LibraryScreen` fixed this by overlaying the header
///    in a `Stack`; the copies never received the fix. That is why the header
///    here is a `Positioned` child and must stay one.
///
/// What it owns: the bar and its height, the derived `chromeTop` and
/// `scrollTopPadding`, the freshness overlay, the pull-to-refresh edge
/// offset, and resetting the ambient backdrop to the calm static fallback
/// (every browse screen wants `BackdropSource.none`; only detail screens
/// publish artwork).
///
/// What it does not own: the grid or list, controllers, data loading, or
/// empty and error states. Those stay with each screen.
class BrowseScaffold extends ConsumerWidget {
  const BrowseScaffold({
    super.key,
    required this.icon,
    required this.title,
    required this.queryKeys,
    required this.body,
    this.actions = const <Widget>[],
    this.secondRow,
    this.onRefresh,
  });

  /// Leading glyph beside [title], tinted with the primary colour.
  final IconData icon;

  /// The screen's name. This is the only place it appears on desktop.
  final String title;

  /// Keys whose combined freshness the overlay header describes.
  final List<QueryKey> queryKeys;

  /// Builds the scrollable body.
  final BrowseBodyBuilder body;

  /// Rendered between [title] and the trailing [CastButton].
  ///
  /// Actions that belong to one breakpoint only (the mobile search shortcut)
  /// are filtered by the calling screen behind its own
  /// [Breakpoints.isDesktop] check. This widget renders whatever it is given.
  final List<Widget> actions;

  /// An optional second bar row, [secondRowHeight] tall, padded to the same
  /// gutters as the content below it. Search is the only user.
  final Widget? secondRow;

  /// Enables pull-to-refresh when supplied.
  final Future<void> Function()? onRefresh;

  /// Height of [secondRow]. Matches `LibraryScreen`'s own search row so the
  /// two bars line up when a user moves between them.
  static const double secondRowHeight = 56;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read MediaQuery here, above the `Scaffold`. Inside the body of a
    // `Scaffold(extendBodyBehindAppBar: true)` Flutter rewrites `padding.top`
    // to the app bar's own bottom edge (see `_BodyBuilder` in
    // material/scaffold.dart), so a descendant that reads it and adds the bar
    // height again counts the bar twice. That was `LibraryScreen`'s original
    // bug and the reason this math lives at the top of the build method.
    final barHeight =
        kToolbarHeight + (secondRow == null ? 0.0 : secondRowHeight);
    final chromeTop = freshnessTopInset(context, appBarHeight: barHeight);
    final scrollTopPadding = chromeTop + 8;

    publishBackdropSource(ref, BackdropSource.none);

    final content = body(context, scrollTopPadding);
    final refresh = onRefresh;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(context, ref, barHeight),
      body: Stack(
        children: [
          if (refresh == null)
            content
          else
            RefreshIndicator(
              edgeOffset: chromeTop,
              onRefresh: refresh,
              child: content,
            ),
          // Overlaid, never a `Column` sibling. See the class doc.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: FreshnessHeader(
              queryKeys: queryKeys,
              topInset: chromeTop,
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    WidgetRef ref,
    double barHeight,
  ) {
    final isDesktop = Breakpoints.isDesktop(context);
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final row = secondRow;

    return PreferredSize(
      preferredSize: Size.fromHeight(barHeight),
      child: GlassSurface.appBar(
        opacity: 0.85,
        child: SafeArea(
          bottom: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: kToolbarHeight,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isDesktop ? horizontalPadding - 8 : 8,
                  ),
                  child: Row(
                    children: [
                      // A pushed screen gets back; a shell destination gets
                      // the drawer. Search is the case that forces this: every
                      // other browse screen reaches it with
                      // `context.push('/search')`, so it sits on top of the
                      // shell navigator, and a hamburger there goes sideways
                      // rather than back. Desktop had no leading control at
                      // all, which made the push a one-way trip.
                      //
                      // `Navigator`, not go_router's `context.canPop()`:
                      // inside the shell route this resolves the shell
                      // navigator, which is exactly what a pushed screen sits
                      // on, and it does not require a GoRouter ancestor, so
                      // this widget stays pumpable in a plain widget test.
                      if (Navigator.of(context).canPop())
                        IconButton(
                          icon: const Icon(Icons.arrow_back_rounded),
                          onPressed: () => Navigator.of(context).maybePop(),
                          tooltip: 'Back',
                        )
                      else if (!isDesktop)
                        IconButton(
                          icon: const Icon(Icons.menu_rounded),
                          onPressed: () {
                            AppShell.scaffoldKey.currentState?.openDrawer();
                          },
                          tooltip: 'Menu',
                        ),
                      // Flexible, and the label ellipsises: this bar uses
                      // `headlineSmall` to match LibraryScreen, which is
                      // larger than the `titleLarge` the old mobile bars
                      // used. "Continue Watching" at that size overflows a
                      // narrow phone bar once the drawer and cast buttons
                      // take their share.
                      Flexible(
                        child: Padding(
                          padding: EdgeInsets.only(left: isDesktop ? 8 : 0),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, color: AppColors.primary, size: 22),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: -0.3,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      ...actions,
                      CastButton(
                        onPressed: () => pickCastDevice(context, ref),
                      ),
                    ],
                  ),
                ),
              ),
              if (row != null)
                SizedBox(
                  height: secondRowHeight,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      0,
                      horizontalPadding,
                      12,
                    ),
                    child: row,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
