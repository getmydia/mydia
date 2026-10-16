// The native iPad sidebar must list exactly what the Flutter sidebar lists.
// Both read sourceNavEntriesProvider; this pins that nativeSidebarFor keeps
// SidebarContent's order and drops nothing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/nav/current_source.dart';
import 'package:player/presentation/widgets/nav/native_sidebar.dart';
import 'package:player/presentation/widgets/nav/sidebar_content.dart';

import '../../screens/sources/fake_media_source.dart';

const _rowPrefix = 'sidebar-row-';

void main() {
  for (final location in [
    '/s/acc1:owner:aa11',
    '/s/acc1:owner:aa11/library/movies',
    '/settings',
  ]) {
    testWidgets('native rows match SidebarContent at $location',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer(overrides: [
        sidebarLayoutStoreProvider
            .overrideWithValue(InMemorySidebarLayoutStore()),
        thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
        hasMydiaProvider.overrideWithValue(true),
        mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              height: 1400,
              child: SidebarContent(
                location: location,
                onNavigate: (_) {},
                isOffline: false,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Settings renders as SettingsSidebarRow, so match on the key alone.
      final rowFinder = find.byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> && key.value.startsWith(_rowPrefix);
      });
      final flutterRows = [
        for (final w in tester.widgetList(rowFinder))
          (w.key! as ValueKey<String>).value.substring(_rowPrefix.length),
      ];

      final sidebar = nativeSidebarFor(
        entries: container.read(sourceNavEntriesProvider(location)),
        servers: const [],
        canFilter: flutterRows.contains('new-filter'),
        isOffline: false,
        showBackToMydia: false,
        sourceHeader: null,
      );
      final nativeRows = [
        for (final item in sidebar.items)
          if (item.id == kNewFilterId)
            'new-filter'
          else if (item.kind == NativeSidebarItemKind.destination)
            item.id,
      ];

      expect(nativeRows, flutterRows);

      // Native opens the trailing group with Edit sidebar, ahead of Downloads
      // and Settings. The Flutter pencil sits in the header, above every row,
      // so it also precedes them.
      final trailing = sidebar.sections.last.items.map((i) => i.id).toList();
      expect(trailing.first, kEditSidebarId);
      final editTop = tester.getTopLeft(find.byTooltip('Edit sidebar')).dy;
      for (final id in ['downloads', 'settings']) {
        final target = find.byKey(ValueKey('$_rowPrefix$id'));
        if (flutterRows.contains(id)) {
          expect(tester.getTopLeft(target).dy, greaterThan(editTop));
        }
      }
    });
  }
}
