import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/nav/menu_page.dart';
import 'package:player/presentation/widgets/nav/sidebar_content.dart';

import '../../screens/sources/fake_capable_source.dart';
import '../../screens/sources/fake_media_source.dart';

/// A stand-in for the shell: a page with a button that opens the menu the
/// way `AppShell` does, recording what the menu asks of it.
class _Host extends ConsumerWidget {
  const _Host({
    required this.state,
    required this.navigated,
    required this.switched,
  });

  final ValueNotifier<MenuPageState> state;
  final List<String> navigated;
  final List<String> switched;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => MenuPage.open(
              context,
              ref: ref,
              state: state,
              onNavigate: navigated.add,
              onSwitchSource: switched.add,
            ),
            child: const Text('open-menu'),
          ),
        ),
      );
}

Future<
    ({
      ValueNotifier<MenuPageState> state,
      List<String> navigated,
      List<String> switched,
      ProviderContainer container,
    })> _openMenu(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = ValueNotifier<MenuPageState>((location: '/', isOffline: false));
  addTearDown(state.dispose);
  final navigated = <String>[];
  final switched = <String>[];
  final container = ProviderContainer(overrides: [
    sidebarLayoutStoreProvider.overrideWithValue(InMemorySidebarLayoutStore()),
    thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
    hasMydiaProvider.overrideWithValue(true),
    mediaSourceProvider(fakeSourceId).overrideWithValue(FakeCapableSource()),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: _Host(state: state, navigated: navigated, switched: switched),
    ),
  ));
  await tester.tap(find.text('open-menu'));
  await tester.pumpAndSettle();
  return (
    state: state,
    navigated: navigated,
    switched: switched,
    container: container,
  );
}

SidebarContent _content(WidgetTester tester) =>
    tester.widget<SidebarContent>(find.byType(SidebarContent));

void main() {
  testWidgets('opens as a full page holding the sidebar', (tester) async {
    await _openMenu(tester);

    expect(find.byType(MenuPage), findsOneWidget);
    expect(find.byType(SidebarContent), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Menu'), findsOneWidget);
    // A page, not a drawer: it covers the screen it was opened from.
    expect(find.text('open-menu'), findsNothing);
  });

  testWidgets('a destination closes the menu, then navigates', (tester) async {
    final menu = await _openMenu(tester);

    await tester.tap(find.descendant(
      of: find.byType(MenuPage),
      matching: find.text('Settings'),
    ));
    await tester.pumpAndSettle();

    expect(menu.navigated, ['/settings']);
    expect(find.byType(MenuPage), findsNothing);
    expect(find.text('open-menu'), findsOneWidget);
  });

  testWidgets('switching server keeps the menu open', (tester) async {
    final menu = await _openMenu(tester);

    _content(tester).onSwitchSource!('/s/other');
    await tester.pumpAndSettle();

    expect(menu.switched, ['/s/other']);
    expect(menu.navigated, isEmpty);
    expect(find.byType(MenuPage), findsOneWidget);
  });

  testWidgets('follows the shell location and offline state while open',
      (tester) async {
    final menu = await _openMenu(tester);
    expect(_content(tester).location, '/');
    expect(_content(tester).isOffline, isFalse);

    menu.state.value = (location: '/downloads', isOffline: true);
    await tester.pump();

    expect(_content(tester).location, '/downloads');
    expect(_content(tester).isOffline, isTrue);
  });

  testWidgets('leaving the menu exits sidebar edit mode', (tester) async {
    final menu = await _openMenu(tester);
    menu.container.read(sidebarEditModeProvider.notifier).toggle();
    await tester.pump();
    expect(menu.container.read(sidebarEditModeProvider), isTrue);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.byType(MenuPage), findsNothing);
    expect(menu.container.read(sidebarEditModeProvider), isFalse);
  });
}
