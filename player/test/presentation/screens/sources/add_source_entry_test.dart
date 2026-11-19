// The only way in for someone with no Mydia server: the login screen's
// "connect Plex or Stash" button and the add-server screen behind it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/router/app_router.dart' show addMydiaRouteRedirect;
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/login_screen.dart';
import 'package:player/presentation/screens/sources/add_source_screen.dart';
import 'package:player/presentation/screens/settings/widgets/settings_row.dart';
import 'package:player/presentation/screens/settings/widgets/settings_section.dart';

import '../../../test_utils/mock_auth_storage.dart';

void main() {
  testWidgets('the login screen offers a way in that opens the add screen',
      (tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/sources/add',
        builder: (_, __) => const SizedBox(key: Key('add-screen-marker')),
      ),
    ]);
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authServiceProvider
            .overrideWithValue(AuthService(storage: MockAuthStorage())),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('connect-other-server'));
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add-screen-marker')), findsOneWidget);
  });

  Future<void> pumpAdd(WidgetTester tester,
          {required bool mydia, bool isWeb = false, bool? remote}) =>
      tester.pumpWidget(ProviderScope(
        overrides: [
          hasMydiaProvider.overrideWithValue(mydia),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AddSourceScreen(isWeb: isWeb, directionalPrimary: remote),
        ),
      ));

  // A row with no callback is dimmed and skipped by focus.
  bool rowEnabled(WidgetTester tester, String key) =>
      tester.widget<SettingsRow>(find.byKey(Key(key))).onTap != null;

  // The key of the row holding primary focus, or null when no row has it.
  Key? focusedRow() => FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<SettingsRow>()
      ?.key;

  group('initial focus', () {
    testWidgets('on a television, Mydia takes focus', (tester) async {
      await pumpAdd(tester, mydia: false, remote: true);
      await tester.pump();
      expect(focusedRow(), const Key('add-source-mydia'));
    });

    testWidgets('on a television with Mydia dimmed, Plex takes focus',
        (tester) async {
      await pumpAdd(tester, mydia: true, isWeb: true, remote: true);
      await tester.pump();
      expect(rowEnabled(tester, 'add-source-mydia'), isFalse);
      expect(focusedRow(), const Key('add-source-plex'));
    });

    testWidgets('with a pointer or touch, no row takes focus', (tester) async {
      await pumpAdd(tester, mydia: false, remote: false);
      await tester.pump();
      expect(focusedRow(), isNull);
    });
  });

  testWidgets('the add screen offers Plex, Stash and Mydia', (tester) async {
    await pumpAdd(tester, mydia: false);
    expect(find.byKey(const Key('add-source-plex')), findsOneWidget);
    expect(find.byKey(const Key('add-source-jellyfin')), findsOneWidget);
    expect(find.byKey(const Key('add-source-stash')), findsOneWidget);
    expect(rowEnabled(tester, 'add-source-mydia'), isTrue);
  });

  List<String> sectionLabels(WidgetTester tester) => tester
      .widgetList<SettingsSection>(find.byType(SettingsSection))
      .map((s) => s.label)
      .toList();

  testWidgets('natively, the rows are grouped Mydia, servers, files, backup',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [hasMydiaProvider.overrideWithValue(false)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AddSourceScreen(isWeb: false, foldersSupported: true),
      ),
    ));
    expect(sectionLabels(tester),
        ['Media servers', 'Files & storage · Experimental', 'Backup']);
    // Mydia sits in an unlabelled card above every section.
    expect(
        tester.getTopLeft(find.byKey(const Key('add-source-mydia'))).dy,
        lessThan(
            tester.getTopLeft(find.byKey(const Key('add-source-plex'))).dy));
    expect(
        find.ancestor(
            of: find.byKey(const Key('add-source-mydia')),
            matching: find.byType(SettingsSection)),
        findsNothing);
    for (final (section, key) in [
      ('Media servers', 'add-source-plex'),
      ('Files & storage · Experimental', 'add-source-folder'),
      ('Files & storage · Experimental', 'add-source-s3'),
      ('Backup', 'add-source-restore'),
    ]) {
      expect(
          find.descendant(
              of: find.byWidgetPredicate(
                  (w) => w is SettingsSection && w.label == section),
              matching: find.byKey(Key(key))),
          findsOneWidget);
    }
  });

  testWidgets('on web, only Mydia and the media servers show', (tester) async {
    await pumpAdd(tester, mydia: false, isWeb: true);
    expect(sectionLabels(tester), ['Media servers']);
    expect(find.byKey(const Key('add-source-mydia')), findsOneWidget);
  });

  testWidgets('Restore from backup is offered natively and opens the screen',
      (tester) async {
    final router = GoRouter(routes: [
      GoRoute(
          path: '/', builder: (_, __) => const AddSourceScreen(isWeb: false)),
      GoRoute(
        path: '/backup/restore',
        builder: (_, __) => const SizedBox(key: Key('restore-marker')),
      ),
    ]);
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [hasMydiaProvider.overrideWithValue(false)],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    final tile = find.byKey(const Key('add-source-restore'));
    expect(tile, findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('restore-marker')), findsOneWidget);
  });

  testWidgets('Restore from backup is not offered on web', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [hasMydiaProvider.overrideWithValue(false)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AddSourceScreen(isWeb: true),
      ),
    ));
    expect(find.byKey(const Key('add-source-restore')), findsNothing);
  });

  testWidgets('only the files and storage rows are marked experimental',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [hasMydiaProvider.overrideWithValue(false)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AddSourceScreen(isWeb: false, foldersSupported: true),
      ),
    ));
    expect(find.text('Files & storage · Experimental').hitTestable(),
        findsOneWidget);
    final experimentalSection = find.byWidgetPredicate((w) =>
        w is SettingsSection && w.label == 'Files & storage · Experimental');
    for (final (key, inside) in [
      ('add-source-folder', true),
      ('add-source-webdav', true),
      ('add-source-smb', true),
      ('add-source-s3', true),
      ('add-source-plex', false),
      ('add-source-jellyfin', false),
      ('add-source-stash', false),
      ('add-source-mydia', false),
      ('add-source-restore', false),
    ]) {
      expect(
          find.descendant(
              of: experimentalSection, matching: find.byKey(Key(key))),
          inside ? findsOneWidget : findsNothing,
          reason: key);
    }
  });

  testWidgets('with a Mydia account, the tile is enabled and adds another',
      (tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const AddSourceScreen()),
      GoRoute(
        path: '/sources/add/mydia',
        builder: (_, __) => const SizedBox(key: Key('guest-marker')),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hasMydiaProvider.overrideWithValue(true),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();

    final tile = find.byKey(const Key('add-source-mydia'));
    expect(rowEnabled(tester, 'add-source-mydia'), isTrue);
    expect(
        find.text("Add a friend's or family member's server"), findsOneWidget);
    expect(find.textContaining('coming soon'), findsNothing);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('guest-marker')), findsOneWidget);
  });

  testWidgets('on web with a Mydia account, the tile is disabled with a hint',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hasMydiaProvider.overrideWithValue(true),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AddSourceScreen(isWeb: true),
      ),
    ));
    expect(rowEnabled(tester, 'add-source-mydia'), isFalse);
    expect(find.text('Add more Mydia servers from the desktop or mobile app'),
        findsOneWidget);
  });

  testWidgets('on web without a Mydia account, the tile still signs in',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hasMydiaProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AddSourceScreen(isWeb: true),
      ),
    ));
    expect(rowEnabled(tester, 'add-source-mydia'), isTrue);
    expect(find.text('Sign in to a Mydia server'), findsOneWidget);
  });

  testWidgets('SMB is offered off web and opens its form', (tester) async {
    final router = GoRouter(routes: [
      GoRoute(
          path: '/', builder: (_, __) => const AddSourceScreen(isWeb: false)),
      GoRoute(
        path: '/sources/add/smb',
        builder: (_, __) => const SizedBox(key: Key('smb-marker')),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [hasMydiaProvider.overrideWithValue(false)],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    final tile = find.byKey(const Key('add-source-smb'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(find.text('A shared folder on a NAS, PC or Mac on your network'),
        findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('smb-marker')), findsOneWidget);
  });

  testWidgets('SMB is hidden on web', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [hasMydiaProvider.overrideWithValue(false)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AddSourceScreen(isWeb: true),
      ),
    ));
    expect(find.byKey(const Key('add-source-smb')), findsNothing);
  });

  testWidgets('S3 is offered off web and opens its form', (tester) async {
    final router = GoRouter(routes: [
      GoRoute(
          path: '/', builder: (_, __) => const AddSourceScreen(isWeb: false)),
      GoRoute(
        path: '/sources/add/s3',
        builder: (_, __) => const SizedBox(key: Key('s3-marker')),
      ),
    ]);
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [hasMydiaProvider.overrideWithValue(false)],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    final tile = find.byKey(const Key('add-source-s3'));
    expect(
        find.text(
            'Amazon S3, Backblaze B2, Cloudflare R2, Wasabi or a self-hosted server'),
        findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('s3-marker')), findsOneWidget);
  });

  testWidgets('S3 is hidden on web', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [hasMydiaProvider.overrideWithValue(false)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AddSourceScreen(isWeb: true),
      ),
    ));
    expect(find.byKey(const Key('add-source-s3')), findsNothing);
  });

  test('the add Mydia route redirects home on an instance-hosted web only', () {
    expect(addMydiaRouteRedirect(hasMydia: true, instanceHostedWeb: true), '/');
    expect(addMydiaRouteRedirect(hasMydia: true, instanceHostedWeb: false),
        isNull);
  });

  testWidgets(
      'a re-auth retitles the login screen and hides the other-server link',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authServiceProvider
            .overrideWithValue(AuthService(storage: MockAuthStorage())),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LoginScreen(reauthAccountId: 'mabc'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Add a Mydia server'), findsOneWidget);
    expect(find.byKey(const Key('connect-other-server')), findsNothing);
  });
}
