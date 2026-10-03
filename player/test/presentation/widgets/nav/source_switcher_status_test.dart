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

void main() {
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
