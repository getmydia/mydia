import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/colors.dart';
import 'window_chrome/window_title_row.dart';

/// The pinned header of the movie, show and episode detail screens.
///
/// The hero art runs to the window's top edge, behind the window controls,
/// and the title row (back, cast) sits in the band on top of it. Before the
/// window-control band existed, each of these screens reserved a flat
/// `AppBar`-height strip and put its own translucent back button and cast
/// button in `leading`/`actions`; that strip is gone, and this builder is
/// what replaced it everywhere at once, so the three screens cannot drift
/// out of alignment with each other or with the rest of the app's chrome.
/// Callers must be under `WindowChromeInsets.removeBand` (via the caller's
/// `Scaffold`), otherwise the ambient `MediaQuery` padding still reserves
/// the band a second time on top of this bar's own [WindowTitleRow.heightOf]
/// toolbar height.
SliverAppBar detailHeroAppBar({
  required BuildContext context,
  required double expandedHeight,
  required Widget back,
  required Widget background,
  bool topScrim = true,
}) {
  final rowHeight = WindowTitleRow.heightOf(context);
  return SliverAppBar(
    expandedHeight: expandedHeight,
    toolbarHeight: rowHeight,
    pinned: true,
    stretch: true,
    backgroundColor: AppColors.background,
    automaticallyImplyLeading: false,
    // NavigationToolbar centers `title` by default and only sizes it to its
    // intrinsic width, which would leave `WindowTitleRow`'s own cast button
    // (an internal child of `title`, not a sibling `actions` entry here)
    // pinned to the middle of the bar instead of the trailing edge. Turning
    // off centering plus stretching the title to the full row width gives
    // `WindowTitleRow`'s own `Row` the whole span to lay leading/cast out
    // against, exactly as it does in `WindowTitleBar`'s `AppBar` slot.
    centerTitle: false,
    titleSpacing: 0,
    title: SizedBox(
      width: double.infinity,
      child: WindowTitleRow(leading: back),
    ),
    flexibleSpace: FlexibleSpaceBar(
      stretchModes: const [
        StretchMode.zoomBackground,
        StretchMode.blurBackground,
      ],
      background: Stack(
        fit: StackFit.expand,
        children: [
          background,
          if (topScrim)
            // Keeps the window controls and the back button legible over
            // bright art, independent of whatever gradient the screen's own
            // background paints lower down for its title/tag overlay.
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 96,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x99000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// The back control for [detailHeroAppBar]'s title row on the movie, show
/// and episode screens.
///
/// Flat like the rest of the title row: the top scrim [detailHeroAppBar]
/// paints keeps the white glyph legible over bright art. Pops when the
/// screen was pushed, otherwise goes home (a deep link has nothing to pop).
class DetailHeroBackButton extends StatelessWidget {
  const DetailHeroBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back_rounded),
      color: Colors.white,
      tooltip: 'Back',
      onPressed: () {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/');
        }
      },
    );
  }
}
