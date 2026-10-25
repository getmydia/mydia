import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';
import 'package:player/presentation/widgets/nav/sidebar_content.dart';
import 'package:player/presentation/widgets/nav/sidebar_row.dart';

import '../../screens/sources/fake_capable_source.dart';
import '../../screens/sources/fake_media_source.dart';

class _MydiaLike extends FakeCapableSource {
  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.continueWatching};
}

Future<void> _pump(
  WidgetTester tester, {
  required String location,
  SidebarLayoutStore? store,
  void Function(String)? onNavigate,
  bool isOffline = false,
  double height = 1400,
  FocusNode? selectedRowFocusNode,
  bool rail = false,
  bool railLabelsVisible = false,
  bool withSwitcher = false,
}) async {
  tester.view.physicalSize = Size(1200, height + 200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sidebarLayoutStoreProvider
            .overrideWithValue(store ?? InMemorySidebarLayoutStore()),
        // A Mydia-like source is the active one, so every location without a
        // source of its own (`/`, `/settings`) resolves against it.
        thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
        hasMydiaProvider.overrideWithValue(true),
        // The switcher only renders when there is a choice of servers.
        if (withSwitcher)
          switchableSourcesProvider.overrideWithValue(const [fakeSource]),
        mediaSourceProvider(fakeSourceId).overrideWithValue(_MydiaLike()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 260,
            height: height,
            child: SidebarContent(
              location: location,
              onNavigate: onNavigate ?? (_) {},
              isOffline: isOffline,
              selectedRowFocusNode: selectedRowFocusNode,
              rail: rail,
              railLabelsVisible: railLabelsVisible,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the default destinations flat, with no expander',
      (tester) async {
    await _pump(tester, location: '/');

    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('TV Shows'), findsOneWidget);
    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    // The old tree's chevron is gone, and so is the Library group header.
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    expect(find.text('Library'), findsNothing);
  });

  testWidgets('does not overflow on a short viewport', (tester) async {
    // The flat list renders every destination at once where the old tree kept
    // Library collapsed, so it is materially taller than what it replaced. A
    // laptop-height sidebar overflowed by ~100px and the render library threw,
    // which only the E2E job caught because every widget test here had been
    // pumping a 1400px column. The anchors stay pinned and the middle scrolls.
    await _pump(tester, location: '/', height: 500);

    expect(tester.takeException(), isNull);

    // Both bottom anchors stay on screen rather than scrolling away. Settings
    // in particular is the only route back from a hidden destination.
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
  });

  testWidgets('a hidden destination is not rendered', (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults.withHidden('collections'));

    await _pump(tester, location: '/', store: store);

    expect(find.text('Collections'), findsNothing);
    expect(find.text('Movies'), findsOneWidget);
  });

  testWidgets('the most specific destination wins the selection',
      (tester) async {
    await _pump(tester, location: '/s/${fakeSourceId.value}/favorites');

    final favorites = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Favorites'),
    );
    final home = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Home'),
    );

    expect(favorites.isSelected, isTrue);
    expect(home.isSelected, isFalse);
  });

  testWidgets('tapping a destination navigates', (tester) async {
    final routes = <String>[];
    await _pump(tester, location: '/', onNavigate: routes.add);

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();

    expect(routes, ['/s/${fakeSourceId.value}/library/movies']);
  });

  testWidgets('anchored rows offer no hide action', (tester) async {
    await _pump(tester, location: '/');

    final settings = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Settings'),
    );
    expect(settings.canCustomise, isFalse);

    final movies = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Movies'),
    );
    expect(movies.canCustomise, isTrue);
  });

  testWidgets('offline disables server-backed rows but not Downloads',
      (tester) async {
    await _pump(tester, location: '/', isOffline: true);

    final movies = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Movies'),
    );
    expect(movies.isDisabled, isTrue);

    final downloads = tester.widget<SidebarRow>(
      find.widgetWithText(SidebarRow, 'Downloads'),
    );
    expect(downloads.isDisabled, isFalse);
  });

  testWidgets('the header offers an edit control', (tester) async {
    await _pump(tester, location: '/');

    expect(find.byTooltip('Edit sidebar'), findsOneWidget);
    expect(find.text('Editing'), findsNothing);
  });

  testWidgets('tapping edit reveals grips and hidden rows', (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults.withHidden('collections'));

    await _pump(tester, location: '/', store: store);
    expect(find.text('Collections'), findsNothing);

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    expect(find.text('Editing'), findsOneWidget);
    expect(find.text('Collections'), findsOneWidget);
    expect(find.byType(ReorderableDragStartListener), findsWidgets);
  });

  testWidgets('a row tap does not navigate while editing', (tester) async {
    final routes = <String>[];
    await _pump(tester, location: '/', onNavigate: routes.add);

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();

    expect(routes, isEmpty);
  });

  testWidgets('Done leaves edit mode', (tester) async {
    await _pump(tester, location: '/');

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();
    expect(find.text('Editing'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('Editing'), findsNothing);
    expect(find.byType(ReorderableDragStartListener), findsNothing);
  });

  testWidgets('the New filter row is hidden while editing', (tester) async {
    await _pump(tester, location: '/');
    expect(find.text('+ New filter'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    expect(find.text('+ New filter'), findsNothing);
  });

  testWidgets('restoring a hidden row unhides it', (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults.withHidden('collections'));

    await _pump(tester, location: '/', store: store);
    expect(find.text('Collections'), findsNothing);

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Restore Collections'));
    await tester.pumpAndSettle();

    expect(store.get()!.hidden, isNot(contains('collections')));

    // The store is only half of it: the mutation also has to invalidate the
    // layout provider, or the sidebar keeps rendering the layout it read
    // before the write. Leaving edit mode is what makes that visible, since
    // edit mode renders hidden rows regardless.
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('Collections'), findsOneWidget);
  });

  testWidgets(
      'the restore control fills its shared 36px slot, and keeps at least a '
      '44px tap height', (tester) async {
    // SidebarRow's trailing slot is a fixed 36px, shared with normal mode's
    // overflow menu; widening it would shift row layout there too. So the
    // restore control's live hit target is 36 wide, exactly the slot, not
    // the 44 its own BoxConstraints requests for height alone — width comes
    // from Material's own default tap-target padding being clamped down
    // into the slot, not from this widget's constraints. Height is at least
    // the requested 44 and, since nothing upstream bounds it, actually lands
    // at Material's own 48px padded minimum.
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults.withHidden('collections'));

    await _pump(tester, location: '/', store: store);

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    final button = find.ancestor(
      of: find.byTooltip('Restore Collections'),
      matching: find.byType(IconButton),
    );
    final size = tester.getSize(button);

    expect(size.width, 36);
    expect(size.height, greaterThanOrEqualTo(44));
  });

  testWidgets('reset asks before it acts, and cancel changes nothing',
      (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults.withHidden('collections'));

    await _pump(tester, location: '/', store: store);

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Reset sidebar'));
    await tester.pumpAndSettle();

    expect(find.text('Reset sidebar?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(store.get()!.hidden, contains('collections'));
  });

  testWidgets('confirming reset unhides everything', (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults.withHidden('collections'));

    await _pump(tester, location: '/', store: store);

    await tester.tap(find.byTooltip('Edit sidebar'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Reset sidebar'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Reset'));
    await tester.pumpAndSettle();

    expect(store.get()!.hidden, isEmpty);
  });

  // The shell hands the sidebar one node and moves focus into it with the
  // D-pad, so "is the node attached to a row?" is the whole contract. A node
  // on no row cannot take focus, and left at the content edge becomes a dead
  // button. Asserted by moving focus rather than by reading the field, since
  // moving focus is what the shell actually does with it.
  testWidgets('the shell node reaches the selected row', (tester) async {
    final node = FocusNode(debugLabel: 'shell-sidebar');
    addTearDown(node.dispose);

    await _pump(tester, location: '/settings', selectedRowFocusNode: node);

    node.requestFocus();
    await tester.pump();

    expect(node.hasFocus, isTrue);
  });

  testWidgets('the shell node reaches a row when nothing is selected',
      (tester) async {
    // A location the sidebar does not list at all — a filter the viewer
    // deleted, or a shared `/filter/<id>` link. No row carries the selection,
    // and without a fallback the node would attach to nothing and the sidebar
    // would be unreachable from the content with a remote.
    final node = FocusNode(debugLabel: 'shell-sidebar');
    addTearDown(node.dispose);

    await _pump(
      tester,
      location: '/filter/no-such-filter',
      selectedRowFocusNode: node,
    );

    node.requestFocus();
    await tester.pump();

    expect(node.hasFocus, isTrue);
  });

  group('rail', () {
    double labelOpacity(WidgetTester tester, String text) => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                  of: find.text(text), matching: find.byType(AnimatedOpacity))
              .first,
        )
        .opacity;

    testWidgets('shows icon boxes with tooltips while labels are hidden',
        (tester) async {
      await _pump(tester, location: '/', rail: true);

      expect(labelOpacity(tester, 'Search'), 0);
      expect(find.byTooltip('Search'), findsOneWidget);
      for (final id in ['search', 'settings']) {
        final row = find.byKey(ValueKey('sidebar-row-$id'));
        expect(tester.getSize(row).height, 48);
        final icon = find.descendant(of: row, matching: find.byType(Icon));
        expect(tester.getSize(icon.first), const Size(22, 22));
      }
    });

    testWidgets('labels show and the tooltips go once expanded',
        (tester) async {
      await _pump(tester, location: '/', rail: true, railLabelsVisible: true);

      expect(labelOpacity(tester, 'Search'), 1);
      expect(find.byTooltip('Search'), findsNothing);
    });

    testWidgets('has no header, and the new-filter row is a normal row',
        (tester) async {
      await _pump(tester, location: '/', rail: true);

      expect(find.byTooltip('Edit sidebar'), findsNothing);
      expect(find.text('Mydia Player'), findsNothing);
      // The full layout shows '+ New filter'; the rail has the same row as an
      // icon with the tooltip "New filter".
      expect(find.text('+ New filter'), findsNothing);
      expect(find.byTooltip('New filter'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('sidebar-row-new-filter')))
            .height,
        48,
      );
    });

    testWidgets('the server switcher icon lines up with the rows',
        (tester) async {
      await _pump(tester, location: '/', rail: true, withSwitcher: true);

      final switcher = find.byKey(const ValueKey('source-switcher-compact'));
      expect(switcher, findsOneWidget);
      expect(tester.getSize(switcher), const Size(48, 48));
      final rowIcon = find.descendant(
        of: find.byKey(const ValueKey('sidebar-row-search')),
        matching: find.byType(Icon),
      );
      expect(
        tester.getCenter(switcher).dx,
        tester.getCenter(rowIcon.first).dx,
      );
    });

    testWidgets('the selected row is ringed and filled', (tester) async {
      await _pump(
        tester,
        location: '/s/${fakeSourceId.value}/favorites',
        rail: true,
      );

      final box = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const ValueKey('sidebar-row-favorites')),
          matching: find.byType(Container),
        ),
      );
      final decoration = box.decoration! as BoxDecoration;
      final border = decoration.border! as Border;
      expect(border.top.color, Palettes.projectionBooth.primary);
      expect(border.top.width, 2);
      expect(decoration.color, Colors.white.withValues(alpha: 0.18));
    });

    testWidgets('exactly one row carries the focus node', (tester) async {
      final node = FocusNode(debugLabel: 'shell-sidebar');
      addTearDown(node.dispose);
      await _pump(
        tester,
        location: '/s/${fakeSourceId.value}/favorites',
        rail: true,
        selectedRowFocusNode: node,
      );

      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      final selectedRow = find.byKey(const ValueKey('sidebar-row-favorites'));
      expect(selectedRow, findsOneWidget);
      // The focused node lives under the selected row, and only one
      // SidebarRow was handed the node.
      expect(
        find.descendant(
          of: selectedRow,
          matching: find.byWidgetPredicate(
            (w) => w is Focus && w.focusNode == node,
          ),
        ),
        findsOneWidget,
      );
      final carriers = tester
          .widgetList<SidebarRow>(find.byType(SidebarRow))
          .where((r) => r.focusNode == node);
      expect(carriers, hasLength(1));
      expect(carriers.single.label, 'Favorites');
    });

    testWidgets('tapping a row navigates', (tester) async {
      final routes = <String>[];
      await _pump(tester, location: '/', rail: true, onNavigate: routes.add);

      await tester.tap(find.byKey(const ValueKey('sidebar-row-movies')));
      await tester.pumpAndSettle();
      expect(routes, ['/s/${fakeSourceId.value}/library/movies']);
    });
  });
}
