// Regression guards for the shell's two remaining inset seams now that each
// screen draws its own title row into the title-bar band:
//
//  * `AppShell.contentInsets` narrows the desktop content column's leading
//    reserve to what `DesktopSidebar` does not already cover, so the column
//    is not padding for window controls the sidebar already sits under.
//  * `AppShell.bannerArea` pads the offline/compatibility/update banner trio
//    down below the band, but only while one of them is actually showing: an
//    idle banner area must not push a screen's own `WindowTitleRow` down out
//    of the band it draws into.
//
// Both are `@visibleForTesting` seams the shell itself calls (see
// app_shell.dart), the same pattern established for `AppShell.dockChrome`: a
// test that exercises the seam directly is not a mirror that could stay
// green if the shell dropped the wiring entirely.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/presentation/widgets/app_shell.dart';

void main() {
  test(
      'the desktop content column does not reserve the lights the sidebar '
      'covers', () {
    const mac = WindowChromeInsets(height: 40, leading: 80, trailing: 0);
    expect(AppShell.contentInsets(mac).leading, 0);

    final linux = WindowChromeInsets(height: 36, leading: 0, trailing: 110);
    expect(AppShell.contentInsets(linux), linux);
  });

  testWidgets('banners still clear the band', (tester) async {
    const bannerKey = Key('banner');

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(top: kMacTitleBarOverlap),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: WindowChromeInsets.scope(
            insets: const WindowChromeInsets(
              height: kMacTitleBarOverlap,
              leading: 80,
              trailing: 0,
            ),
            // `Align` loosens the constraints `_PadTopWhenNonEmpty` receives:
            // `pumpWidget` otherwise hands the root a size tight to the test
            // surface, and this widget's own layout logic (sizing itself to
            // `child.height + top` rather than the incoming constraint) needs
            // room to do that, exactly as it gets from the real `Column` the
            // shell mounts it in.
            child: Align(
              alignment: Alignment.topLeft,
              child: AppShell.bannerArea(
                child: const SizedBox(height: 30, width: 100, key: bannerKey),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.getRect(find.byKey(bannerKey)).top, kMacTitleBarOverlap);
  });

  testWidgets('an empty banner area takes no space', (tester) async {
    const areaKey = Key('banner-area');

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(top: kMacTitleBarOverlap),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            // `AppShell.bannerArea` returns a private render object widget,
            // so it cannot be found by type from outside app_shell.dart.
            // `KeyedSubtree` is transparent to layout (`build` just returns
            // `child`), so its element's `renderObject` resolves straight
            // through to the area's own, letting the key measure it.
            child: KeyedSubtree(
              key: areaKey,
              child: AppShell.bannerArea(child: const SizedBox.shrink()),
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(areaKey)).height, 0);
  });
}
