import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/nav/source_switcher.dart';

class _FixedAuth extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.authenticated);
}

const _plexSource = Source(
  account: ProviderAccount(
    id: 'acc1',
    kind: SourceKind.plex,
    displayName: 'someone@example.test',
    storageNamespace: 'source/acc1',
    activeProfileId: 'owner',
  ),
  profile: SourceProfile(
    id: 'owner',
    accountId: 'acc1',
    name: 'Owner',
    isOwner: true,
  ),
  server: SourceServer(
    id: 'srv9',
    accountId: 'acc1',
    profileId: 'owner',
    name: 'Basement',
  ),
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required List<Source> thirdParty,
  required List<String> navigations,
}) async {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(_FixedAuth.new),
      thirdPartySourcesProvider.overrideWithValue(thirdParty),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SourceSwitcher(onNavigate: navigations.add),
        ),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('renders nothing with only the Mydia source', (tester) async {
    await _pump(tester, thirdParty: const [], navigations: []);
    expect(find.byType(InkWell), findsNothing);
    expect(find.text('Mydia'), findsNothing);
    final size = tester.getSize(find.byType(SourceSwitcher));
    expect(size.height, 0);
  });

  testWidgets('lists every source once a second exists', (tester) async {
    await _pump(tester, thirdParty: [_plexSource], navigations: []);
    expect(find.byKey(const ValueKey('source-switcher-mydia')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('source-switcher-acc1:owner:srv9')),
      findsOneWidget,
    );
  });

  testWidgets('selecting a third-party source navigates to its root',
      (tester) async {
    final navigations = <String>[];
    final container = await _pump(tester,
        thirdParty: [_plexSource], navigations: navigations);

    await tester
        .tap(find.byKey(const ValueKey('source-switcher-acc1:owner:srv9')));
    await tester.pump();

    expect(container.read(activeSourceIdProvider), _plexSource.id);
    expect(navigations, ['/s/acc1:owner:srv9']);
  });

  testWidgets('selecting Mydia navigates to the existing home', (tester) async {
    final navigations = <String>[];
    await _pump(tester, thirdParty: [_plexSource], navigations: navigations);

    await tester.tap(find.byKey(const ValueKey('source-switcher-mydia')));
    await tester.pump();

    expect(navigations, ['/']);
  });
}
