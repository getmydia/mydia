import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/nav/source_switcher.dart';

import '../../screens/sources/fake_media_source.dart';

class _Authenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.authenticated);
}

Future<List<String>> pump(
    WidgetTester tester, Source source, FakeMediaSource fake) async {
  final navigations = <String>[];
  await tester.pumpWidget(ProviderScope(
    overrides: [
      authStateProvider.overrideWith(_Authenticated.new),
      thirdPartySourcesProvider.overrideWithValue([source]),
      mediaSourceProvider(source.id).overrideWithValue(fake),
    ],
    child: MaterialApp(
      home: Scaffold(body: SourceSwitcher(onNavigate: navigations.add)),
    ),
  ));
  await tester.pump();
  return navigations;
}

Source _source(String account, String server, {bool presence = true}) => Source(
      account: ProviderAccount(
        id: account,
        kind: SourceKind.plex,
        displayName: 'name-$account',
        storageNamespace: 'source/$account',
        activeProfileId: 'owner',
      ),
      profile: SourceProfile(
          id: 'owner', accountId: account, name: 'Quill', isOwner: true),
      server: SourceServer(
          id: server,
          accountId: account,
          profileId: 'owner',
          name: 'Server $server',
          presence: presence),
    );

Future<void> _pumpMany(WidgetTester tester, List<Source> sources) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      authStateProvider.overrideWith(_Authenticated.new),
      thirdPartySourcesProvider.overrideWithValue(sources),
      for (final s in sources)
        mediaSourceProvider(s.id).overrideWithValue(FakeMediaSource()),
    ],
    child: MaterialApp(
      home: Scaffold(body: SourceSwitcher(onNavigate: (_) {})),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('groups servers under one caption per account', (tester) async {
    await _pumpMany(tester, [
      _source('acc1', 'aa11'),
      _source('acc2', 'bb22'),
      _source('acc1', 'cc33'),
    ]);
    expect(find.byKey(const ValueKey('source-switcher-account-acc1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('source-switcher-account-acc2')),
        findsOneWidget);
    expect(find.text('name-acc1'), findsOneWidget);
    // Both acc1 servers sit before acc2's caption.
    final acc2Top = tester
        .getTopLeft(find.byKey(const ValueKey('source-switcher-account-acc2')))
        .dy;
    for (final id in ['acc1:owner:aa11', 'acc1:owner:cc33']) {
      expect(tester.getTopLeft(find.byKey(ValueKey('source-switcher-$id'))).dy,
          lessThan(acc2Top));
    }
  });

  testWidgets('a server that is offline is dimmed even while local',
      (tester) async {
    await _pumpMany(tester, [_source('acc1', 'aa11', presence: false)]);
    final opacity = tester.widget<Opacity>(find
        .ancestor(
            of: find.byKey(const ValueKey('source-switcher-acc1:owner:aa11')),
            matching: find.byType(Opacity))
        .first);
    expect(opacity.opacity, lessThan(1));
  });

  testWidgets('offers add and manage once there is a choice', (tester) async {
    final navigations = await pump(tester, fakeSource, FakeMediaSource());
    await tester.tap(find.byKey(const ValueKey('source-switcher-add')));
    await tester.tap(find.byKey(const ValueKey('source-switcher-manage')));
    expect(navigations, ['/sources/add', '/sources/manage']);
  });

  testWidgets('an account that needs sign-in sends the tap to re-auth',
      (tester) async {
    const flagged = Source(
      account: ProviderAccount(
        id: 'acc1',
        kind: SourceKind.plex,
        displayName: 'quill',
        storageNamespace: 'source/acc1',
        activeProfileId: 'owner',
        needsReauth: true,
      ),
      profile: SourceProfile(
          id: 'owner', accountId: 'acc1', name: 'Quill', isOwner: true),
      server: SourceServer(
          id: 'aa11', accountId: 'acc1', profileId: 'owner', name: 'Attic'),
    );
    final navigations = await pump(tester, flagged, FakeMediaSource());
    expect(find.textContaining('sign in again'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('source-switcher-acc1:owner:aa11')));
    expect(navigations, ['/sources/add/plex?account=acc1']);
  });

  testWidgets('an unreachable server is dimmed', (tester) async {
    final fake = FakeMediaSource();
    await pump(tester, fakeSource, fake);
    Opacity opacity() => tester.widget<Opacity>(find
        .ancestor(
            of: find.byKey(const ValueKey('source-switcher-acc1:owner:aa11')),
            matching: find.byType(Opacity))
        .first);
    expect(opacity().opacity, 1);
    (fake.statusListenable as ValueNotifier<SourceConnectionStatus>).value =
        SourceConnectionStatus.unreachable;
    await tester.pump();
    expect(opacity().opacity, lessThan(1));
  });
}
