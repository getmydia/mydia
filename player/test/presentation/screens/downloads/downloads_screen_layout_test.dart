// Regression guard for the blank sliver above Downloads' storage section:
// `DownloadsScreen.topSpacerHeight` must track the header's real height
// (`WindowTitleRow.heightOf`: the window-chrome band height on macOS/Linux,
// `kToolbarHeight` everywhere else) plus the fixed breathing-room gap
// `DownloadsScreen.storageSectionGap`, not the old flat `100` that stopped
// tracking the header once its height started varying by platform (fix
// round 1 of task 5: the storage section drifted from 44px below the header
// to 60px on macOS once the header shrank from 56 to 40, because the spacer
// stayed a flat literal).
//
// Uses `DownloadsScreen.header` and `DownloadsScreen.topSpacerHeight`
// directly, in the same `Scaffold`/`CustomScrollView` shape `build` uses,
// rather than mounting the full screen: `DownloadsScreen.build` stands up
// the download queue, storage-quota and downloaded-media providers together
// (several Hive-backed), which is expensive to satisfy just to check where
// the first content sliver lands.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/presentation/screens/downloads/downloads_screen.dart';
import 'package:player/presentation/widgets/window_chrome/window_title_row.dart';

const _markerKey = Key('first-content-sliver');

/// Mounts the real header and the real spacer formula in the same shape
/// `DownloadsScreen.build` uses, with a keyed marker sliver standing in for
/// the storage section (the actual first content sliver).
Future<void> _pumpHarness(
  WidgetTester tester, {
  required WindowChromeInsets insets,
  required double statusBar,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        downloadQueueProvider.overrideWith(
          (ref) => Stream.value(<DownloadTask>[]),
        ),
        castCapabilitiesProvider.overrideWithValue(
          const CastCapabilities.full(),
        ),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            padding: EdgeInsets.only(top: statusBar + insets.height),
          ),
          child: WindowChromeInsets.scope(
            insets: insets,
            // Mirrors `DownloadsScreen.build`'s own wrap: the header draws
            // into the band itself, so the body sits under `removeBand`.
            child: WindowChromeInsets.removeBand(
              child: Consumer(
                builder: (context, ref, _) => Scaffold(
                  extendBodyBehindAppBar: true,
                  appBar: DownloadsScreen.header(context, ref),
                  body: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: DownloadsScreen.topSpacerHeight(context),
                        ),
                      ),
                      const SliverToBoxAdapter(
                        child: SizedBox(height: 10, key: _markerKey),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'the first content sliver starts at the header bottom plus the '
      'storage gap, under macOS insets', (tester) async {
    const macOS = WindowChromeInsets(height: 40, leading: 80, trailing: 0);
    await _pumpHarness(tester, insets: macOS, statusBar: 0);

    final headerBottom = tester.getRect(find.byType(WindowTitleRow)).bottom;
    final markerTop = tester.getRect(find.byKey(_markerKey)).top;

    // The header itself must be exactly the band height (40) with no status
    // bar folded in twice, otherwise the spacer offset below would be right
    // for the wrong reason.
    expect(headerBottom, 40);
    expect(markerTop, headerBottom + DownloadsScreen.storageSectionGap);
  });

  testWidgets(
      'the first content sliver starts at the header bottom plus the '
      'storage gap, with a 24px status bar and no window chrome',
      (tester) async {
    await _pumpHarness(
      tester,
      insets: WindowChromeInsets.zero,
      statusBar: 24,
    );

    final headerBottom = tester.getRect(find.byType(WindowTitleRow)).bottom;
    final markerTop = tester.getRect(find.byKey(_markerKey)).top;

    // Pre-Task-5, the header's true rendered height (its own SafeArea plus
    // kToolbarHeight) was 24 + 56 = 80, and the flat spacer was 100 -- a
    // 44px gap that only matched by coincidence when the status bar was 0.
    // `topSpacerHeight` now adds the real status bar instead of ignoring it.
    expect(headerBottom, 24 + kToolbarHeight);
    expect(markerTop, headerBottom + DownloadsScreen.storageSectionGap);
  });
}
