import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/platform/native_tab_bar_channel.dart';
import 'package:player/core/router/legacy_routes.dart';
import 'package:player/core/sources/current_source_status.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/domain/navigation/all_servers_locations.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';
import 'package:player/presentation/widgets/nav/all_servers_server_rows.dart';
import 'package:player/presentation/widgets/nav/native_sidebar.dart';
import 'package:player/presentation/widgets/nav/native_sidebar_host.dart';

import '../../../domain/merged/fake_merged_source.dart';
import '../../../test_utils/mock_auth_storage.dart';

const _name = 'test/all-servers-switch';
const _channel = MethodChannel(_name);

SourceAccountRecord _record(String id) => SourceAccountRecord(
      account: ProviderAccount(
        id: id,
        kind: SourceKind.plex,
        displayName: 'Server $id',
        storageNamespace: 'source/$id',
        activeProfileId: 'owner',
      ),
      profiles: [
        SourceProfile(id: 'owner', accountId: id, name: 'Owner', isOwner: true),
      ],
      servers: [
        SourceServer(
            id: 's1',
            accountId: id,
            profileId: 'owner',
            name: 'Server $id',
            machineIdentifier: 's1'),
      ],
      addedAtMs: 1700000000000,
    );

SourceId _idOf(String account) => SourceId('$account:owner:s1');

/// Real records, sources and active-source providers; only the per-source
/// connections are faked.
Future<ProviderContainer> _container(WidgetTester tester,
    {bool routerLike = false}) async {
  final store = InMemorySourceStore();
  await store.putAccount(_record('a'));
  await store.putAccount(_record('b'));
  final fakes = <SourceId, FakeMergedSource>{};
  final container = ProviderContainer(overrides: [
    nativeTabBarChannelProvider.overrideWith((ref) {
      final channel = NativeTabBarChannel(channel: _channel);
      ref.onDispose(channel.dispose);
      return channel;
    }),
    sidebarLayoutStoreProvider.overrideWithValue(InMemorySidebarLayoutStore()),
    sourceStoreProvider.overrideWith((ref) async => store),
    sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
    mediaSourceProvider.overrideWith((ref, id) => fakes.putIfAbsent(
        id, () => FakeMergedSource(fakeServer(id.value.split(':').first)))),
  ]);
  addTearDown(container.dispose);
  await container.read(sourceRecordsProvider.future);
  if (routerLike) {
    // What appRouter does: refresh on a pick, and the redirect it runs
    // reads the active source.
    void redirect() {
      container.read(sourcesLoadingProvider);
      container.read(thirdPartySourcesProvider);
      container.read(gatedSourceIdsProvider);
      container.read(legacyMydiaSourceIdProvider);
      container.read(mydiaSourceIdsProvider);
      container.read(activeSourceIdProvider);
      container.read(allServersChoicesProvider);
    }

    container.listen(thirdPartySourcesProvider, (_, __) => redirect());
    container.listen(sourcesLoadingProvider, (_, __) => redirect());
    container.listen(selectedSourceIdProvider, (_, __) => redirect());
    container.listen(legacyMydiaSourceIdProvider, (_, __) => redirect());
    container.listen(mydiaSourceIdsProvider, (_, __) => redirect());
    container.listen(gatedSourceIdsProvider, (_, __) => redirect());
  }
  return container;
}

void _size(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));
}

/// What AppShell does on every build: `_isOfflineMode` watches the route's
/// source status, which on All servers reads the active source.
class _ShellProbe extends ConsumerWidget {
  const _ShellProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(routeSourceStatusProvider(allServersRoot));
    return const SizedBox.shrink();
  }
}

void main() {
  testWidgets('native sidebar: tapping a server row on All servers',
      (tester) async {
    _size(tester);
    final container = await _container(tester, routerLike: true);
    final navigated = <String>[];
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(children: [
            const _ShellProbe(),
            Expanded(
              child: NativeSidebarHost(
                location: allServersRoot,
                onNavigate: navigated.add,
                visible: true,
                isOffline: false,
              ),
            ),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _name,
      const StandardMethodCodec().encodeMethodCall(
          MethodCall('tabSelected', serverItemId(_idOf('b')))),
      (_) {},
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(container.read(activeSourceIdProvider), _idOf('b'));
    expect(navigated, [sourceHomeLocation(_idOf('b'))]);
  });

  testWidgets('flutter rail: tapping a server row on All servers',
      (tester) async {
    _size(tester);
    final container = await _container(tester, routerLike: true);
    final navigated = <String>[];
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(children: [
            const _ShellProbe(),
            AllServersServerRows(onNavigate: navigated.add),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(ValueKey('all-server-row-${_idOf('b').value}')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(container.read(activeSourceIdProvider), _idOf('b'));
    expect(navigated, [sourceHomeLocation(_idOf('b'))]);
  });
}
