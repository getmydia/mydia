import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/platform/native_tab_bar_channel.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/navigation/all_servers_locations.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';
import 'package:player/presentation/widgets/nav/native_sidebar.dart';
import 'package:player/presentation/widgets/nav/native_sidebar_host.dart';
import 'package:player/presentation/widgets/nav/source_picker.dart';

import '../../screens/sources/fake_media_source.dart';

const _otherId = SourceId('acc1:owner:bb22');
const _name = 'test/native-sidebar-host';
const _channel = MethodChannel(_name);

class _Harness {
  _Harness(this.calls, this.navigated, this.container);
  final List<MethodCall> calls;
  final List<String> navigated;
  final ProviderContainer container;

  List<String> get methods => [for (final c in calls) c.method];

  Object? last(String method) =>
      calls.lastWhere((c) => c.method == method).arguments;

  Future<void> fromNative(
      WidgetTester tester, String method, Object? args) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
    await tester.pump();
  }
}

Future<_Harness> _pump(
  WidgetTester tester, {
  String location = '/s/acc1:owner:aa11',
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final calls = <MethodCall>[];
  final navigated = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel,
      (call) async {
    calls.add(call);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  final media = FakeMediaSource();
  final other = FakeMediaSource(id: _otherId);
  final container = ProviderContainer(overrides: [
    nativeTabBarChannelProvider.overrideWith((ref) {
      final channel = NativeTabBarChannel(channel: _channel);
      ref.onDispose(channel.dispose);
      return channel;
    }),
    sidebarLayoutStoreProvider.overrideWithValue(InMemorySidebarLayoutStore()),
    // Two servers, so the switcher (and its picker) has a choice to offer.
    sourcesProvider.overrideWithValue([media.source, other.source]),
    hasMydiaProvider.overrideWithValue(false),
    mediaSourceProvider(fakeSourceId).overrideWithValue(media),
    mediaSourceProvider(_otherId).overrideWithValue(other),
    allServersSourcesProvider.overrideWithValue([media, other]),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: NativeSidebarHost(
          location: location,
          onNavigate: navigated.add,
          visible: true,
          isOffline: false,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return _Harness(calls, navigated, container);
}

void main() {
  testWidgets('sends the sidebar, the selection and visibility',
      (tester) async {
    final h =
        await _pump(tester, location: '/s/acc1:owner:aa11/library/movies');
    // Order varies: the first build can precede the nav entries settling.
    expect(h.methods, containsAll(['setSidebar', 'select', 'setVisible']));
    final payload = h.last('setSidebar') as Map;
    final ids = [
      for (final s in payload['sections'] as List)
        for (final i in (s as Map)['items'] as List) (i as Map)['id'],
    ];
    expect(ids.first, kSourceHeaderId);
    expect(ids.last, 'settings');
    expect(h.last('select'), 'movies');
    expect(h.last('setVisible'), isTrue);
  });

  testWidgets('a route with no row clears the selection', (tester) async {
    final h = await _pump(tester, location: '/sources/manage');
    expect(h.methods, contains('select'));
    expect(h.last('select'), isNull);
  });

  testWidgets('a destination tap navigates to its route', (tester) async {
    final h = await _pump(tester);
    await h.fromNative(tester, 'tabSelected', 'settings');
    expect(h.navigated, ['/settings']);
  });

  testWidgets('a server row switches to that server', (tester) async {
    final h = await _pump(tester, location: allServersRoot);
    await h.fromNative(tester, 'tabSelected', serverItemId(fakeSourceId));
    expect(h.navigated, [sourceHomeLocation(fakeSourceId)]);
    expect(h.container.read(selectedSourceIdProvider), fakeSourceId);
  });

  testWidgets('Edit sidebar opens the edit sheet', (tester) async {
    final h = await _pump(tester);
    await h.fromNative(tester, 'tabSelected', kEditSidebarId);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sidebar-edit-sheet')), findsOneWidget);
  });

  testWidgets('the header opens the source picker', (tester) async {
    final h = await _pump(tester);
    await h.fromNative(tester, 'tabSelected', kSourceHeaderId);
    await tester.pumpAndSettle();
    expect(find.byType(SourcePickerList), findsOneWidget);
  });

  testWidgets('an unknown id is ignored', (tester) async {
    final h = await _pump(tester);
    await h.fromNative(tester, 'tabSelected', 'nope');
    expect(h.navigated, isEmpty);
  });

  testWidgets('dispose hides the sidebar', (tester) async {
    final h = await _pump(tester);
    await tester.pumpWidget(const SizedBox());
    expect(h.last('setVisible'), isFalse);
  });
}
