import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/nav/sidebar_row.dart';
import 'package:player/presentation/widgets/nav/source_picker.dart';

import '../../../domain/merged/fake_merged_source.dart';
import '../../screens/sources/fake_media_source.dart';

class _Authenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.authenticated);
}

Source _source(
  String account,
  String server, {
  bool presence = true,
  bool needsReauth = false,
}) =>
    Source(
      account: ProviderAccount(
        id: account,
        kind: SourceKind.plex,
        displayName: 'name-$account',
        storageNamespace: 'source/$account',
        activeProfileId: 'owner',
        needsReauth: needsReauth,
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

/// Opens the picker from a button standing in for the sidebar header, and
/// returns the list the picker's result lands in.
Future<List<PickerChoice?>> _open(
  WidgetTester tester,
  List<Source> sources, {
  SourceId? currentId = SourceId.legacyMydia,
  Size size = const Size(800, 600),
  Map<SourceId, FakeMediaSource> fakes = const {},
  List<SourceProfile> profiles = const [],
  List<MediaSource> included = const [],
}) async {
  // `size` is a logical size, so pin the pixel ratio; the default of 3 would
  // make every layout here a phone.
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final results = <PickerChoice?>[];
  await tester.pumpWidget(ProviderScope(
    overrides: [
      authStateProvider.overrideWith(_Authenticated.new),
      thirdPartySourcesProvider.overrideWithValue(sources),
      allServersSourcesProvider.overrideWithValue(included),
      for (final s in sources)
        mediaSourceProvider(s.id)
            .overrideWithValue(fakes[s.id] ?? FakeMediaSource()),
      for (final account in {for (final s in sources) s.account.id})
        accountProfilesProvider(account).overrideWithValue([
          for (final p in profiles)
            if (p.accountId == account) p
        ]),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 240,
            child: Builder(
              builder: (context) => TextButton(
                key: const Key('open-picker'),
                onPressed: () async => results
                    .add(await showSourcePicker(context, currentId: currentId)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open-picker')));
  await tester.pumpAndSettle();
  return results;
}

Finder _row(String id) => find.byKey(ValueKey('source-switcher-$id'));

void main() {
  testWidgets('All servers is the first row once two servers are included',
      (tester) async {
    final a = _source('acc1', 'aa11');
    final b = _source('acc2', 'bb22');
    final results = await _open(tester, [
      a,
      b
    ], included: [
      FakeMergedSource(a),
      FakeMergedSource(b),
    ]);
    expect(_row('all'), findsOneWidget);
    expect(tester.getTopLeft(_row('all')).dy,
        lessThan(tester.getTopLeft(_row('mydia')).dy));
    await tester.tap(_row('all'));
    await tester.pumpAndSettle();
    expect(results.single, isA<PickAllServers>());
  });

  testWidgets('at /all the All servers row is current and no source row is',
      (tester) async {
    final guest = _source('acc1', 'aa11');
    final results = await _open(
      tester,
      [guest],
      currentId: null,
      included: [
        FakeMergedSource(Source.legacyMydia()),
        FakeMergedSource(guest)
      ],
    );
    bool selected(Finder f) => tester.widget<SidebarRow>(f).isSelected;
    expect(selected(_row('all')), isTrue);
    expect(selected(_row('mydia')), isFalse);
    expect(selected(_row(guest.id.value)), isFalse);
    expect(tester.widget<SidebarRow>(_row('all')).focusNode?.hasFocus, isTrue);
    await tester.tap(_row('mydia'));
    await tester.pumpAndSettle();
    expect(results.single, isA<PickSource>());
  });

  testWidgets('no All servers row with fewer than two', (tester) async {
    final a = _source('acc1', 'aa11');
    await _open(tester, [a], included: [FakeMergedSource(a)]);
    expect(_row('all'), findsNothing);
  });

  testWidgets('groups servers under one caption per account', (tester) async {
    await _open(tester, [
      _source('acc1', 'aa11'),
      _source('acc2', 'bb22'),
      _source('acc1', 'cc33'),
    ]);
    expect(find.byKey(const ValueKey('source-switcher-account-acc1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('source-switcher-account-acc2')),
        findsOneWidget);
    final acc2Top = tester
        .getTopLeft(find.byKey(const ValueKey('source-switcher-account-acc2')))
        .dy;
    for (final id in ['acc1:owner:aa11', 'acc1:owner:cc33']) {
      expect(tester.getTopLeft(_row(id)).dy, lessThan(acc2Top));
    }
    // Mydia heads the list and has no caption.
    expect(_row('mydia'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-switcher-account-mydia')),
        findsNothing);
  });

  testWidgets('a guest Mydia gets its account caption, home does not',
      (tester) async {
    const guest = Source(
      account: ProviderAccount(
        id: 'mguest',
        kind: SourceKind.mydia,
        displayName: 'Lakeside',
        storageNamespace: 'source/mguest',
        activeProfileId: 'owner',
      ),
      profile: SourceProfile(
          id: 'owner', accountId: 'mguest', name: 'Owner', isOwner: true),
      server: SourceServer(
          id: 'inst-2',
          accountId: 'mguest',
          profileId: 'owner',
          name: 'Lakeside'),
    );
    await _open(tester, [guest]);
    expect(find.byKey(const ValueKey('source-switcher-account-mguest')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('source-switcher-account-mydia')),
        findsNothing);
  });

  testWidgets('picking a source returns it and closes', (tester) async {
    final results = await _open(tester, [_source('acc1', 'aa11')]);
    await tester.tap(_row('acc1:owner:aa11'));
    await tester.pumpAndSettle();
    expect(results, hasLength(1));
    expect((results.single! as PickSource).source.id,
        const SourceId('acc1:owner:aa11'));
    expect(find.byKey(const ValueKey('source-picker')), findsNothing);
  });

  testWidgets('a Plex Home with other users offers Switch user',
      (tester) async {
    final results = await _open(tester, [
      _source('acc1', 'aa11'),
      _source('acc2', 'bb22'),
    ], profiles: const [
      SourceProfile(
          id: 'owner', accountId: 'acc1', name: 'Quill', isOwner: true),
      SourceProfile(
          id: 'kid0001', accountId: 'acc1', name: 'Pip', isOwner: false),
      SourceProfile(
          id: 'owner', accountId: 'acc2', name: 'Wren', isOwner: true),
    ]);
    final switchUser =
        find.byKey(const ValueKey('source-switcher-switch-user-acc1'));
    expect(switchUser, findsOneWidget);
    expect(find.byKey(const ValueKey('source-switcher-switch-user-acc2')),
        findsNothing,
        reason: 'a Home of one has nobody to switch to');
    await tester.tap(switchUser);
    await tester.pumpAndSettle();
    expect((results.single! as SwitchUser).account.id, 'acc1');
  });

  testWidgets('add and manage return their own choices', (tester) async {
    final results = await _open(tester, [_source('acc1', 'aa11')]);
    await tester.tap(find.byKey(const ValueKey('source-switcher-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-switcher-manage')));
    await tester.pumpAndSettle();
    expect(results[0], isA<AddServer>());
    expect(results[1], isA<ManageServers>());
  });

  testWidgets('the current source has focus when the picker opens',
      (tester) async {
    await _open(tester, [_source('acc1', 'aa11'), _source('acc2', 'bb22')],
        currentId: const SourceId('acc2:owner:bb22'));
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find.descendant(
        of: _row('acc2:owner:bb22'),
        matching: find.byElementPredicate((e) => e == focused),
      ),
      findsOneWidget,
    );
  });

  testWidgets('focus reaches a current server that starts off-screen',
      (tester) async {
    final sources = [
      for (var i = 0; i < 15; i++) _source('acc$i', 'srv$i'),
    ];
    await _open(tester, sources,
        currentId: const SourceId('acc14:owner:srv14'),
        size: const Size(1280, 500));
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find.descendant(
        of: _row('acc14:owner:srv14'),
        matching: find.byElementPredicate((e) => e == focused),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an account that needs sign-in says so', (tester) async {
    await _open(tester, [_source('acc1', 'aa11', needsReauth: true)]);
    expect(find.textContaining('sign in again'), findsOneWidget);
  });

  testWidgets('an offline server is dimmed', (tester) async {
    await _open(tester, [_source('acc1', 'aa11', presence: false)]);
    final opacity = tester.widget<Opacity>(find
        .ancestor(of: _row('acc1:owner:aa11'), matching: find.byType(Opacity))
        .first);
    expect(opacity.opacity, lessThan(1));
  });

  testWidgets('an unreachable server dims while the picker is open',
      (tester) async {
    final source = _source('acc1', 'aa11');
    final fake = FakeMediaSource();
    await _open(tester, [source], fakes: {source.id: fake});
    double opacity() => tester
        .widget<Opacity>(find
            .ancestor(
                of: _row('acc1:owner:aa11'), matching: find.byType(Opacity))
            .first)
        .opacity;
    expect(opacity(), 1);
    (fake.statusListenable as ValueNotifier<SourceConnectionStatus>).value =
        SourceConnectionStatus.unreachable;
    await tester.pump();
    expect(opacity(), lessThan(1));
  });

  testWidgets('narrow layouts use a bottom sheet', (tester) async {
    await _open(tester, [_source('acc1', 'aa11')]);
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('wide layouts hang a popover under the anchor', (tester) async {
    await _open(tester, [_source('acc1', 'aa11')], size: const Size(1280, 900));
    expect(find.byType(BottomSheet), findsNothing);
    final anchorBottom =
        tester.getBottomLeft(find.byKey(const Key('open-picker'))).dy;
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('source-picker'))).dy,
      greaterThanOrEqualTo(anchorBottom),
    );
  });

  testWidgets('Escape closes the popover with no choice', (tester) async {
    final results = await _open(tester, [_source('acc1', 'aa11')],
        size: const Size(1280, 900));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(find.byKey(const ValueKey('source-picker')), findsNothing);
  });
}
