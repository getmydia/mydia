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

Source _plex({bool needsReauth = false}) => Source(
      account: ProviderAccount(
        id: 'acc1',
        kind: SourceKind.plex,
        displayName: 'someone@example.test',
        storageNamespace: 'source/acc1',
        activeProfileId: 'owner',
        needsReauth: needsReauth,
      ),
      profile: const SourceProfile(
        id: 'owner',
        accountId: 'acc1',
        name: 'Owner',
        isOwner: true,
      ),
      server: const SourceServer(
        id: 'srv9',
        accountId: 'acc1',
        profileId: 'owner',
        name: 'Basement',
      ),
    );

class _Calls {
  final navigations = <String>[];
  final switches = <String>[];
}

Future<(ProviderContainer, _Calls)> _pump(
  WidgetTester tester, {
  required List<Source> thirdParty,
  String location = '/',
  bool withSwitchCallback = true,
}) async {
  final calls = _Calls();
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
          body: SourceSwitcher(
            location: location,
            onNavigate: calls.navigations.add,
            onSwitchSource: withSwitchCallback ? calls.switches.add : null,
          ),
        ),
      ),
    ),
  );
  return (container, calls);
}

const _header = ValueKey('source-switcher-header');

String _headerName(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('source-switcher-header-name')))
    .data!;

Future<void> _openAndTap(WidgetTester tester, Key row) async {
  await tester.tap(find.byKey(_header));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(row));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders nothing with only the Mydia source', (tester) async {
    await _pump(tester, thirdParty: const []);
    expect(find.byKey(_header), findsNothing);
    expect(tester.getSize(find.byType(SourceSwitcher)).height, 0);
  });

  testWidgets('is one row, not a list of servers', (tester) async {
    await _pump(tester, thirdParty: [_plex()]);
    expect(find.byKey(_header), findsOneWidget);
    expect(find.byKey(const ValueKey('source-switcher-acc1:owner:srv9')),
        findsNothing);
    expect(find.byKey(const ValueKey('source-switcher-add')), findsNothing);
  });

  testWidgets('names the server the page belongs to', (tester) async {
    await _pump(tester,
        thirdParty: [_plex()], location: '/s/acc1:owner:srv9/library/x');
    expect(_headerName(tester), 'Basement');
  });

  testWidgets('names Mydia on a Mydia page even when Plex is remembered',
      (tester) async {
    final (container, _) =
        await _pump(tester, thirdParty: [_plex()], location: '/settings');
    container.read(selectedSourceIdProvider.notifier).select(_plex().id);
    await tester.pump();
    expect(_headerName(tester), 'Mydia');
  });

  testWidgets('the Mydia header does not repeat its name as a caption',
      (tester) async {
    await _pump(tester, thirdParty: [_plex()]);
    expect(
      find.descendant(of: find.byKey(_header), matching: find.text('Mydia')),
      findsOneWidget,
    );
  });

  testWidgets('a third-party header keeps its account caption', (tester) async {
    await _pump(tester,
        thirdParty: [_plex()], location: '/s/acc1:owner:srv9/library/x');
    expect(find.text('Plex · someone@example.test'), findsOneWidget);
  });

  testWidgets('a Plex Home with other users names the active one',
      (tester) async {
    final calls = _Calls();
    final container = ProviderContainer(overrides: [
      authStateProvider.overrideWith(_FixedAuth.new),
      thirdPartySourcesProvider.overrideWithValue([_plex()]),
      accountProfilesProvider('acc1').overrideWithValue(const [
        SourceProfile(
            id: 'owner', accountId: 'acc1', name: 'Owner', isOwner: true),
        SourceProfile(
            id: 'kid0001', accountId: 'acc1', name: 'Pip', isOwner: false),
      ]),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SourceSwitcher(
            location: '/s/acc1:owner:srv9',
            onNavigate: calls.navigations.add,
          ),
        ),
      ),
    ));
    expect(find.text('Plex · someone@example.test · Owner'), findsOneWidget);
  });

  testWidgets('the header is announced as a button naming the server',
      (tester) async {
    await _pump(tester, thirdParty: [_plex()]);
    expect(find.bySemanticsLabel(RegExp('Switch server')), findsOneWidget);
  });

  testWidgets('switching servers selects it and uses onSwitchSource',
      (tester) async {
    final (container, calls) = await _pump(tester, thirdParty: [_plex()]);
    await _openAndTap(
        tester, const ValueKey('source-switcher-acc1:owner:srv9'));
    expect(container.read(activeSourceIdProvider), _plex().id);
    expect(calls.switches, ['/s/acc1:owner:srv9']);
    expect(calls.navigations, isEmpty);
  });

  testWidgets('switching to Mydia goes home', (tester) async {
    final (_, calls) = await _pump(tester,
        thirdParty: [_plex()], location: '/s/acc1:owner:srv9');
    await _openAndTap(tester, const ValueKey('source-switcher-mydia'));
    expect(calls.switches, ['/']);
  });

  testWidgets('without onSwitchSource a switch goes through onNavigate',
      (tester) async {
    final (_, calls) =
        await _pump(tester, thirdParty: [_plex()], withSwitchCallback: false);
    await _openAndTap(
        tester, const ValueKey('source-switcher-acc1:owner:srv9'));
    expect(calls.navigations, ['/s/acc1:owner:srv9']);
  });

  testWidgets('add and manage navigate', (tester) async {
    final (_, calls) = await _pump(tester, thirdParty: [_plex()]);
    await _openAndTap(tester, const ValueKey('source-switcher-add'));
    await _openAndTap(tester, const ValueKey('source-switcher-manage'));
    expect(calls.navigations, ['/sources/add', '/sources/manage']);
    expect(calls.switches, isEmpty);
  });

  testWidgets('an account that needs sign-in routes to re-auth',
      (tester) async {
    final flagged = _plex(needsReauth: true);
    final (_, calls) = await _pump(tester,
        thirdParty: [flagged], location: '/s/acc1:owner:srv9');
    expect(find.text('Sign in again'), findsOneWidget);
    await _openAndTap(
        tester, const ValueKey('source-switcher-acc1:owner:srv9'));
    expect(calls.navigations, ['/sources/add/plex?account=acc1']);
    expect(calls.switches, isEmpty);
  });

  test('currentFor prefers the location, then Mydia, then the pick', () {
    final plex = _plex();
    final mydia = Source.legacyMydia();
    expect(
        SourceSwitcher.currentFor(
            [mydia, plex], '/s/acc1:owner:srv9', mydia.id),
        plex);
    expect(
        SourceSwitcher.currentFor([mydia, plex], '/settings', plex.id), mydia);
    expect(SourceSwitcher.currentFor([plex], '/sources/manage', plex.id), plex);
  });
}
