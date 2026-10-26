import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/core/layout/dock_insets.dart';
import 'package:player/core/platform/native_tab_bar_channel.dart';
import 'package:player/domain/navigation/source_nav.dart';
import 'package:player/l10n/gen/app_localizations_en.dart';
import 'package:player/presentation/widgets/nav/bottom_nav.dart';
import 'package:player/presentation/widgets/nav/native_tab_bar.dart';
import 'package:player/presentation/widgets/toast/toast_obstruction.dart';

final _en = AppLocalizationsEn();
const _name = 'test/native-tab-bar';
const _channel = MethodChannel(_name);

SourceNavEntry _entry(String id, String route, {bool shortLabel = false}) =>
    SourceNavEntry(
      id: id,
      label: '${id[0].toUpperCase()}${id.substring(1)}',
      shortLabel: shortLabel,
      icon: Icons.circle_outlined,
      selectedIcon: Icons.circle,
      route: route,
    );

final _all = [
  _entry('home', '/s/aa'),
  _entry('movies', '/s/aa/library/movies'),
  _entry('shows', '/s/aa/library/shows', shortLabel: true),
  _entry('favorites', '/s/aa/favorites'),
  _entry('downloads', '/downloads'),
  _entry('settings', '/settings'),
];

final _bar = bottomNavEntries(_all, downloadSupported: true);

class _Harness {
  _Harness(this.calls, this.navigated);
  final List<MethodCall> calls;
  final List<String> navigated;

  List<String> get log => [for (final c in calls) '${c.method}:${c.arguments}'];
}

/// Pumps [NativeTabBar] as the shell does: the mobile Scaffold's
/// bottomNavigationBar, with `extendBody`.
Future<_Harness> _pump(
  WidgetTester tester, {
  required ProviderContainer container,
  String location = '/s/aa',
  bool visible = true,
  bool isOffline = false,
  double homeIndicator = 0,
  ValueSetter<double>? onDockInset,
  List<String>? navigated,
  List<MethodCall>? calls,
}) async {
  final recorded = calls ?? <MethodCall>[];
  final routes = navigated ?? <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel,
      (call) async {
    recorded.add(call);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MediaQuery(
      data: MediaQueryData(
        size: const Size(400, 800),
        padding: EdgeInsets.only(bottom: homeIndicator),
        viewPadding: EdgeInsets.only(bottom: homeIndicator),
      ),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          extendBody: true,
          bottomNavigationBar: NativeTabBar(
            location: location,
            entries: _bar,
            visible: visible,
            isOffline: isOffline,
            onNavigate: routes.add,
            onBackToMydia: () => routes.add('mydia-app'),
          ),
          body: Builder(builder: (context) {
            onDockInset?.call(DockInsets.bottomOf(context));
            return const SizedBox.expand();
          }),
        ),
      ),
    ),
  ));
  await tester.pump();
  return _Harness(recorded, routes);
}

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [
    nativeTabBarChannelProvider.overrideWith((ref) {
      final channel = NativeTabBarChannel(channel: _channel);
      ref.onDispose(channel.dispose);
      return channel;
    }),
  ]);
  addTearDown(container.dispose);
  return container;
}

Future<void> _fromNative(WidgetTester tester, String method,
        [Object? arguments]) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _name,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );

void main() {
  group('nativeTabsFor', () {
    test('the bar entries, in order, with symbols and short labels', () {
      final tabs = nativeTabsFor(_bar,
          l10n: _en, isOffline: false, showBackToMydia: false);
      expect([for (final t in tabs) t.id],
          ['home', 'movies', 'shows', 'downloads', 'settings']);
      expect([
        for (final t in tabs) t.symbol
      ], [
        'house.fill',
        'film.fill',
        'tv.fill',
        'arrow.down.circle.fill',
        'gearshape.fill',
      ]);
      expect(tabs[2].title, 'Shows');
      expect(tabs.every((t) => t.enabled), isTrue);
    });

    test('Favorites replaces Downloads where downloads are unsupported', () {
      final tabs = nativeTabsFor(
        bottomNavEntries(_all, downloadSupported: false),
        l10n: _en,
        isOffline: false,
        showBackToMydia: false,
      );
      expect([for (final t in tabs) t.id],
          ['home', 'movies', 'shows', 'favorites', 'settings']);
      expect(tabs[3].symbol, 'heart.fill');
    });

    test('embed mode leads with the Mydia back item', () {
      final tabs = nativeTabsFor(_bar,
          l10n: _en, isOffline: true, showBackToMydia: true);
      expect(tabs.first.id, kMydiaBackTabId);
      expect(tabs.first.title, 'Mydia');
      expect(tabs.first.symbol, 'chevron.backward');
      // The way back out stays usable offline.
      expect(tabs.first.enabled, isTrue);
    });

    test('offline disables everything except Downloads', () {
      final tabs = nativeTabsFor(_bar,
          l10n: _en, isOffline: true, showBackToMydia: false);
      expect({
        for (final t in tabs) t.id: t.enabled
      }, {
        'home': false,
        'movies': false,
        'shows': false,
        'downloads': true,
        'settings': false,
      });
    });

    test('the badge goes on Settings only', () {
      final tabs = nativeTabsFor(_bar,
          l10n: _en,
          isOffline: false,
          showBackToMydia: false,
          settingsBadge: '1');
      expect({
        for (final t in tabs) t.id: t.badge
      }, {
        'home': null,
        'movies': null,
        'shows': null,
        'downloads': null,
        'settings': '1',
      });
    });

    test('an unknown id gets a circle', () {
      expect(nativeTabSymbol('f-123'), 'circle');
    });
  });

  test('settingsTabBadge marks a waiting update only', () {
    expect(settingsTabBadge(updatePending: true), '1');
    expect(settingsTabBadge(updatePending: false), isNull);
  });

  group('selectedNativeTabId', () {
    test('the entry the location falls under', () {
      expect(selectedNativeTabId(_bar, '/s/aa/library/movies/42'), 'movies');
      expect(selectedNativeTabId(_bar, '/s/aa'), 'home');
    });

    test('null where no entry matches', () {
      expect(selectedNativeTabId(_bar, '/sources/manage'), isNull);
    });
  });

  testWidgets('mount sends tabs, the selection and visibility, in that order',
      (tester) async {
    final h = await _pump(tester,
        container: _container(), location: '/s/aa/library/movies');
    expect(h.calls.map((c) => c.method), ['setTabs', 'select', 'setVisible']);
    expect(h.log.sublist(1), ['select:movies', 'setVisible:true']);
  });

  testWidgets('no matching entry sends no select', (tester) async {
    final h = await _pump(tester,
        container: _container(), location: '/sources/manage');
    expect(h.calls.map((c) => c.method), ['setTabs', 'setVisible']);
  });

  testWidgets('rebuilds with nothing new send nothing', (tester) async {
    final container = _container();
    final calls = <MethodCall>[];
    await _pump(tester, container: container, calls: calls);
    calls.clear();
    await _pump(tester, container: container, calls: calls);
    expect(calls, isEmpty);
  });

  testWidgets('a tap navigates to the entry route; unknown ids are ignored',
      (tester) async {
    final h = await _pump(tester, container: _container());
    await _fromNative(tester, 'tabSelected', 'movies');
    await _fromNative(tester, 'tabSelected', 'calendar');
    await tester.pump();
    expect(h.navigated, ['/s/aa/library/movies']);
  });

  testWidgets('the back item leaves for the Mydia app', (tester) async {
    final h = await _pump(tester, container: _container());
    await _fromNative(tester, 'tabSelected', kMydiaBackTabId);
    await tester.pump();
    expect(h.navigated, ['mydia-app']);
  });

  testWidgets('a refused route leaves the selection where it was',
      (tester) async {
    final container = _container();
    final calls = <MethodCall>[];
    await _pump(tester, container: container, calls: calls);
    await _fromNative(tester, 'tabSelected', 'movies');
    // The shell refused (offline): the location did not change.
    calls.clear();
    await _pump(tester, container: container, calls: calls);
    expect(calls.where((c) => c.method == 'select'), isEmpty);
  });

  testWidgets('a redirected route selects where it landed', (tester) async {
    final container = _container();
    final calls = <MethodCall>[];
    await _pump(tester, container: container, calls: calls);
    await _fromNative(tester, 'tabSelected', 'movies');
    // The router redirected the Movies tap to Downloads.
    calls.clear();
    await _pump(tester,
        container: container, calls: calls, location: '/downloads');
    expect([for (final c in calls) '${c.method}:${c.arguments}'],
        ['select:downloads']);
  });

  testWidgets('hidden sends setVisible(false); unmount hides the bar',
      (tester) async {
    final container = _container();
    final calls = <MethodCall>[];
    await _pump(tester, container: container, calls: calls, visible: false);
    expect(calls.last.arguments, false);

    await _pump(tester, container: container, calls: calls, visible: true);
    expect(calls.last.arguments, true);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect('${calls.last.method}:${calls.last.arguments}', 'setVisible:false');
  });

  testWidgets('before the first inset, the dock height stands in',
      (tester) async {
    double? dockInset;
    await _pump(tester,
        container: _container(),
        homeIndicator: 34,
        onDockInset: (v) => dockInset = v);
    expect(tester.getSize(find.byKey(const Key('native-tab-bar-inset'))).height,
        NativeTabBar.fallbackBarHeight + 34);
    expect(dockInset, NativeTabBar.fallbackBarHeight + 34 + DockInsets.dockGap);
  });

  testWidgets('the native inset reaches DockInsets.bottomOf', (tester) async {
    double? dockInset;
    await _pump(tester,
        container: _container(),
        homeIndicator: 34,
        onDockInset: (v) => dockInset = v);
    await _fromNative(tester, 'insetsChanged', 120.0);
    await tester.pump();
    expect(dockInset, 120 + DockInsets.dockGap);
  });

  testWidgets('insetsChanged(0) keeps the last height', (tester) async {
    double? dockInset;
    await _pump(tester,
        container: _container(), onDockInset: (v) => dockInset = v);
    await _fromNative(tester, 'insetsChanged', 120.0);
    await tester.pump();
    await _fromNative(tester, 'insetsChanged', 0.0);
    await tester.pump();
    expect(dockInset, 120 + DockInsets.dockGap);
  });

  testWidgets('claims the inset as a bottom toast obstruction, and passes taps',
      (tester) async {
    await _pump(tester, container: _container());
    final obstruction =
        tester.widget<ToastObstruction>(find.byType(ToastObstruction));
    expect(obstruction.edge, ToastEdge.bottom);
    expect(obstruction.active, isTrue);
    expect(
      find.ancestor(
          of: find.byKey(const Key('native-tab-bar-inset')),
          matching: find.byType(IgnorePointer)),
      findsWidgets,
    );
  });
}
