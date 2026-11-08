import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/files/smb_discovery.dart';
import 'package:player/core/sources/files/smb_native.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/sources/add_smb_screen.dart';

import '../../../core/sources/files/fake_backend.dart';
import '../../../core/sources/files/fake_media_names.dart';
import '../../../core/sources/files/fake_smb_discovery.dart';
import '../../../core/sources/files/fake_smb_native.dart';
import '../../../core/sources/files/files_fixture.dart';
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';

class _RecordingNative extends FakeSmbNative {
  final listed = <(String, int, SmbCredentials)>[];
  bool noShares = false;

  /// Hosts whose share listing is unreachable, as a dead interface.
  final unreachableHosts = <String>{};

  @override
  Future<List<String>> listShares(
      String host, int port, SmbCredentials c) async {
    listed.add((host, port, c));
    if (unreachableHosts.contains(host)) {
      throw BackendUnreachable('no route to $host');
    }
    final shares = await super.listShares(host, port, c);
    return noShares ? const [] : shares;
  }
}

class _Harness {
  _Harness(this.box, this.store, this.storage, this.native, this.discovery);

  final Box<Map<dynamic, dynamic>> box;
  final InMemorySourceStore store;
  final MockAuthStorage storage;
  final _RecordingNative native;
  final FakeSmbDiscovery discovery;
  late final GoRouter router;
}

int _boxes = 0;

const _attic =
    DiscoveredSmbServer(name: 'Attic NAS', host: '192.168.1.20', port: 445);

Future<_Harness> _pump(
  WidgetTester tester, {
  String? reauthAccountId,
  _Harness? reuse,
  TargetPlatform platform = TargetPlatform.android,
  Duration timeout = const Duration(seconds: 5),
}) async {
  var box = reuse?.box;
  if (box == null) {
    final opened = (await tester.runAsync(() =>
        Hive.openBox<Map<dynamic, dynamic>>('smb_screen_${_boxes++}',
            bytes: Uint8List(0))))!;
    addTearDown(() => tester.runAsync(opened.close));
    box = opened;
  }
  final native = _RecordingNative()
    ..addDir('media', '/Films')
    ..addDir('media', '/Shows')
    ..addFile('media', '/Films/Amber Tide (2019).mkv');
  final h = _Harness(
    box,
    reuse?.store ?? InMemorySourceStore(),
    reuse?.storage ?? MockAuthStorage(),
    native,
    FakeSmbDiscovery(),
  );
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  h.router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => const Text('home')),
      GoRoute(
          path: '/s/:id',
          builder: (_, s) => Text('opened ${s.pathParameters['id']}')),
      GoRoute(
          path: '/add',
          builder: (_, __) => AddSmbScreen(
                reauthAccountId: reauthAccountId,
                platform: platform,
                discoveryTimeout: timeout,
              )),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...noHiveOverrides,
      sourceStoreProvider.overrideWith((ref) async => h.store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(h.storage)),
      filesIndexBoxProvider.overrideWithValue(h.box),
      filesProgressStoreProvider
          .overrideWithValue(InMemoryPlaybackProgressStore()),
      mediaNamesProvider.overrideWithValue(FakeMediaNames()),
      relayTmdbProvider.overrideWithValue(FakeFilesRelay()),
      filesBackendBuilderProvider
          .overrideWithValue((ref, source) => FakeBackend({})),
      smbNativeProvider.overrideWithValue(native),
      smbDiscoveryProvider.overrideWithValue(h.discovery),
    ],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: h.router,
    ),
  ));
  await tester.pumpAndSettle();
  unawaited(h.router.push('/add'));
  await tester.pumpAndSettle();
  return h;
}

Future<void> _enter(WidgetTester tester, String key, String text) =>
    tester.enterText(find.byKey(Key(key)), text);

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _viaDiscovery(WidgetTester tester, _Harness h) async {
  h.discovery.emit([_attic]);
  await tester.pumpAndSettle();
  await _tap(tester, 'smb-server-192.168.1.20');
}

void main() {
  testWidgets('a discovered server leads to the login with its host filled',
      (tester) async {
    final h = await _pump(tester);
    expect(find.byKey(const Key('smb-servers')), findsOneWidget);
    await _viaDiscovery(tester, h);

    expect(find.byKey(const Key('smb-login')), findsOneWidget);
    final host = tester
        .widget<TextField>(find.byKey(const Key('smb-host-field')))
        .controller!
        .text;
    expect(host, '192.168.1.20');
  });

  testWidgets('the manual row shows its hint and accepts an address',
      (tester) async {
    final h = await _pump(tester);
    expect(find.text('Windows PCs usually need to be entered by address.'),
        findsOneWidget);
    await _tap(tester, 'smb-manual');
    await _enter(tester, 'smb-host-field', 'nas.example.test');
    await _enter(tester, 'smb-port-field', '4445');
    await _enter(tester, 'smb-user-field', 'viewer');
    await _enter(tester, 'smb-password-field', 'pw');
    await _enter(tester, 'smb-domain-field', 'HOME');
    await _tap(tester, 'smb-connect-button');

    final (host, port, creds) = h.native.listed.single;
    expect((host, port), ('nas.example.test', 4445));
    expect(
        (creds.user, creds.password, creds.domain), ('viewer', 'pw', 'HOME'));
    expect(find.byKey(const Key('smb-shares')), findsOneWidget);
  });

  testWidgets('guest connects with an empty user', (tester) async {
    final h = await _pump(tester);
    await _viaDiscovery(tester, h);
    await _tap(tester, 'smb-guest');

    final (_, _, creds) = h.native.listed.single;
    expect((creds.user, creds.password, creds.domain), ('', '', null));
    expect(find.byKey(const Key('smb-shares')), findsOneWidget);
  });

  testWidgets('a share, folders and kinds save one account with one root',
      (tester) async {
    final h = await _pump(tester);
    await _viaDiscovery(tester, h);
    await _enter(tester, 'smb-user-field', 'viewer');
    await _enter(tester, 'smb-password-field', 'pw');
    await _tap(tester, 'smb-connect-button');
    await _tap(tester, 'smb-share-media');

    await tester.tap(find.byKey(const Key('smb-tick-/Films')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('smb-kind-/Films')));
    await tester.pumpAndSettle();
    await tester.tap(find
        .descendant(
            of: find.byKey(const ValueKey('files-kind-movies')).last,
            matching: find.byType(Text))
        .last);
    await tester.pumpAndSettle();
    await _tap(tester, 'smb-save-button');

    final accountId = smbAccountId(Uri.parse('smb://192.168.1.20/media'));
    final record = (await h.store.load()).accounts.single;
    expect(record.account.id, accountId);
    final secret = await h.storage
        .read('${record.account.storageNamespace}/account_token');
    expect(SmbCredentials.fromJson(secret!).user, 'viewer');
    final roots = {
      for (final r in FileLibraryIndex(h.box, accountId: accountId).roots())
        r.path: r,
    };
    expect(roots.keys, ['/Films']);
    expect(roots['/Films']!.kind, FilesLibraryKind.movies);
    // Saved: the new source opens.
    expect(find.byKey(const Key('smb-folders')), findsNothing);
    expect(find.text('opened $accountId:owner:$accountId'), findsOneWidget);
  });

  testWidgets('a discovered server names the account with its own name',
      (tester) async {
    final h = await _pump(tester);
    await _viaDiscovery(tester, h);
    await _tap(tester, 'smb-guest');
    await _tap(tester, 'smb-share-media');
    await tester.tap(find.byKey(const Key('smb-tick-/Films')));
    await tester.pumpAndSettle();
    await _tap(tester, 'smb-save-button');

    final record = (await h.store.load()).accounts.single;
    expect(record.account.displayName, 'Attic NAS / media');
  });

  testWidgets('a typed server names the account host/share', (tester) async {
    final h = await _pump(tester);
    await _tap(tester, 'smb-manual');
    await _enter(tester, 'smb-host-field', '10.0.0.9');
    await _tap(tester, 'smb-guest');
    await _tap(tester, 'smb-share-media');
    await tester.tap(find.byKey(const Key('smb-tick-/Films')));
    await tester.pumpAndSettle();
    await _tap(tester, 'smb-save-button');

    final record = (await h.store.load()).accounts.single;
    expect(record.account.displayName, '10.0.0.9/media');
  });

  testWidgets('leaving the folder step unsaved closes the account',
      (tester) async {
    final h = await _pump(tester);
    await _viaDiscovery(tester, h);
    await _tap(tester, 'smb-guest');
    await _tap(tester, 'smb-share-media');
    expect(h.native.closedAccounts, isEmpty);

    h.router.pop();
    await tester.pumpAndSettle();
    expect(h.native.closedAccounts,
        [smbAccountId(Uri.parse('smb://192.168.1.20/media'))]);
  });

  group('errors', () {
    Future<_Harness> failing(WidgetTester tester, BackendFailure f) async {
      final h = await _pump(tester);
      await _viaDiscovery(tester, h);
      h.native.failure = f;
      await _tap(tester, 'smb-guest');
      return h;
    }

    testWidgets('unreachable', (tester) async {
      await failing(tester, const BackendUnreachable('boom'));
      expect(find.text("Can't reach the server."), findsOneWidget);
    });

    testWidgets('unauthorized', (tester) async {
      await failing(tester, const BackendUnauthorized());
      expect(find.text('The username or password is wrong.'), findsOneWidget);
    });

    testWidgets('not found', (tester) async {
      await failing(tester, const BackendNotFound('gone'));
      expect(find.text('That shared folder no longer exists on this server.'),
          findsOneWidget);
    });

    testWidgets('access denied', (tester) async {
      await failing(tester, const BackendPermissionLost('no'));
      expect(find.text("This account can't open that folder."), findsOneWidget);
    });

    testWidgets('a host:port address is split, not read as IPv6',
        (tester) async {
      for (final (typed, host, port) in [
        ('nas.local:4455', 'nas.local', 4455),
        ('192.168.1.5:445', '192.168.1.5', 445),
        ('fe80::1', 'fe80::1', 445),
        ('[fe80::1]', 'fe80::1', 445),
      ]) {
        final h = await _pump(tester);
        await _tap(tester, 'smb-manual');
        await _enter(tester, 'smb-host-field', typed);
        await _tap(tester, 'smb-guest');
        final (gotHost, gotPort, _) = h.native.listed.single;
        expect((gotHost, gotPort), (host, port), reason: typed);
      }
    });

    testWidgets('a bad inline port is an invalid address', (tester) async {
      for (final typed in ['nas.local:0', 'nas.local:70000', 'nas.local:x']) {
        final h = await _pump(tester);
        await _tap(tester, 'smb-manual');
        await _enter(tester, 'smb-host-field', typed);
        await _tap(tester, 'smb-guest');
        expect(h.native.listed, isEmpty, reason: typed);
        expect(find.textContaining('between 1 and 65535'), findsOneWidget,
            reason: typed);
      }
    });

    testWidgets('SMB1 only', (tester) async {
      await failing(tester, const BackendUnreachable(kSmb1OnlyReason));
      expect(find.textContaining('only speaks SMB1'), findsOneWidget);
    });

    testWidgets('no shares', (tester) async {
      final h = await _pump(tester);
      h.native.noShares = true;
      await _tap(tester, 'smb-manual');
      await _enter(tester, 'smb-host-field', '10.0.0.9');
      await _tap(tester, 'smb-guest');
      expect(find.text('This server has no shared folders you can open.'),
          findsOneWidget);
      expect(find.byKey(const Key('smb-shares')), findsNothing);
    });
  });

  group('discovery empty states', () {
    testWidgets('an error shows none found, and no iOS hint on android',
        (tester) async {
      final h = await _pump(tester);
      h.discovery.fail();
      await tester.pumpAndSettle();
      expect(
          find.text('No file shares found on this network.'), findsOneWidget);
      expect(find.textContaining('Allow local network access'), findsNothing);
    });

    testWidgets('five quiet seconds show none found', (tester) async {
      await _pump(tester, timeout: const Duration(seconds: 5));
      expect(find.text('No file shares found on this network.'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(
          find.text('No file shares found on this network.'), findsOneWidget);
    });

    testWidgets('iOS adds the local network hint', (tester) async {
      final h = await _pump(tester, platform: TargetPlatform.iOS);
      h.discovery.fail();
      await tester.pumpAndSettle();
      expect(
          find.text('No file shares found on this network.'), findsOneWidget);
      expect(find.textContaining('Allow local network access'), findsOneWidget);
    });
  });

  group('a saved share', () {
    final accountId = smbAccountId(Uri.parse('smb://192.168.1.20/media'));

    /// Saves the attic share with `/Films`, signed in with password `old`,
    /// optionally marked as needing a new sign-in, then opens the screen
    /// for it again.
    Future<_Harness> reopen(WidgetTester tester,
        {required bool needsReauth}) async {
      final h = await _pump(tester);
      await _viaDiscovery(tester, h);
      await _enter(tester, 'smb-password-field', 'old');
      await _enter(tester, 'smb-user-field', 'viewer');
      await _tap(tester, 'smb-connect-button');
      await _tap(tester, 'smb-share-media');
      await tester.tap(find.byKey(const Key('smb-tick-/Films')));
      await tester.pumpAndSettle();
      await _tap(tester, 'smb-save-button');
      if (needsReauth) {
        final record = (await h.store.load()).accounts.single;
        await h.store.putAccount(record.copyWith(
            account: record.account.copyWith(needsReauth: true)));
      }
      await tester.pumpWidget(const SizedBox());
      return _pump(tester, reauthAccountId: accountId, reuse: h);
    }

    Future<String?> password(_Harness h) async {
      final record = (await h.store.load()).accounts.single;
      final secret = await h.storage
          .read('${record.account.storageNamespace}/account_token');
      return SmbCredentials.fromJson(secret!).password;
    }

    Future<void> signIn(WidgetTester tester, String password) async {
      await _enter(tester, 'smb-user-field', 'viewer');
      await _enter(tester, 'smb-password-field', password);
      await _tap(tester, 'smb-connect-button');
    }

    testWidgets('signing in again keeps the share and replaces the credentials',
        (tester) async {
      final h = await reopen(tester, needsReauth: true);
      expect(find.byKey(const Key('smb-login')), findsOneWidget);
      expect(find.byKey(const Key('smb-servers')), findsNothing);
      expect(
          tester
              .widget<TextField>(find.byKey(const Key('smb-host-field')))
              .controller!
              .text,
          '192.168.1.20');

      await signIn(tester, 'new');
      expect(h.native.listed, isEmpty, reason: 'never lists shares');
      // The saved share was checked with the new password before saving.
      final (target, login) = h.native.probeLogins.single;
      expect((target.host, target.port, target.share),
          ('192.168.1.20', 445, 'media'));
      expect((login.user, login.password), ('viewer', 'new'));

      expect(find.byKey(const Key('smb-shares')), findsNothing);
      final record = (await h.store.load()).accounts.single;
      expect(record.account.id, accountId);
      expect(record.account.needsReauth, isFalse);
      expect(await password(h), 'new');
      expect(
          FileLibraryIndex(h.box, accountId: accountId).roots(), hasLength(1));
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('a refused sign-in keeps the old credentials', (tester) async {
      final h = await reopen(tester, needsReauth: true);
      h.native.failure = const BackendUnauthorized();
      await signIn(tester, 'wrong');

      expect(find.text('The username or password is wrong.'), findsOneWidget);
      expect(find.byKey(const Key('smb-login')), findsOneWidget);
      final record = (await h.store.load()).accounts.single;
      expect(record.account.needsReauth, isTrue);
      expect(await password(h), 'old');
    });

    testWidgets('add folders signs in, then opens the folder picker',
        (tester) async {
      final h = await reopen(tester, needsReauth: false);
      await signIn(tester, 'new');

      expect(find.byKey(const Key('smb-folders')), findsOneWidget);
      expect(await password(h), 'old', reason: 'saved with the folders');
      await tester.tap(find.byKey(const Key('smb-tick-/Shows')));
      await tester.pumpAndSettle();
      await _tap(tester, 'smb-save-button');

      final roots = FileLibraryIndex(h.box, accountId: accountId).roots();
      expect(roots.map((r) => r.path), unorderedEquals(['/Films', '/Shows']));
      expect(await password(h), 'new');
      // The source's playback URLs are its own: never closed from here.
      expect(h.native.closedAccounts, isEmpty);
      expect(find.text('opened $accountId:owner:$accountId'), findsOneWidget);
    });
  });

  testWidgets('back at a share root returns to the share list', (tester) async {
    final h = await _pump(tester);
    await _viaDiscovery(tester, h);
    await _tap(tester, 'smb-guest');
    await _tap(tester, 'smb-share-media');
    expect(find.byKey(const Key('smb-folders')), findsOneWidget);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
    await navigator.maybePop();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('smb-shares')), findsOneWidget);
    expect(h.native.closedAccounts,
        [smbAccountId(Uri.parse('smb://192.168.1.20/media'))]);
    // The sign-in is kept: the share opens again without one.
    await _tap(tester, 'smb-share-media');
    expect(find.byKey(const Key('smb-folders')), findsOneWidget);
    expect(h.native.listed, hasLength(1));
  });

  testWidgets('an unreachable advertised address moves on to the next',
      (tester) async {
    final h = await _pump(tester);
    h.native.unreachableHosts.add('172.17.0.1');
    h.discovery.emit([
      const DiscoveredSmbServer(
          name: 'Attic NAS',
          host: '172.17.0.1',
          port: 445,
          alternatives: ['192.168.1.20']),
    ]);
    await tester.pumpAndSettle();
    await _tap(tester, 'smb-server-172.17.0.1');
    await _tap(tester, 'smb-guest');

    expect(h.native.listed.map((l) => l.$1), ['172.17.0.1', '192.168.1.20']);
    await _tap(tester, 'smb-share-media');
    await tester.tap(find.byKey(const Key('smb-tick-/Films')));
    await tester.pumpAndSettle();
    await _tap(tester, 'smb-save-button');

    final record = (await h.store.load()).accounts.single;
    expect(
        record.account.id, smbAccountId(Uri.parse('smb://192.168.1.20/media')));
  });

  testWidgets('signing in again to a missing account cannot connect',
      (tester) async {
    final h = await _pump(tester, reauthAccountId: 'sdeadbeefdeadbeef');

    expect(find.byKey(const Key('smb-error')), findsOneWidget);
    expect(
        find.text('Could not save this share on this device.'), findsOneWidget);
    for (final key in ['smb-connect-button', 'smb-guest']) {
      final f = find.byKey(Key(key));
      await tester.ensureVisible(f);
      await tester.tap(f, warnIfMissed: false);
      await tester.pumpAndSettle();
    }
    expect(h.native.listed, isEmpty);
    expect(find.byKey(const Key('smb-shares')), findsNothing);
    expect((await h.store.load()).accounts, isEmpty);
  });
}
