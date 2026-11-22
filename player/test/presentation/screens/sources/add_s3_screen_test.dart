import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/backend/s3_backend.dart';
import 'package:player/core/sources/files/backend/s3_errors.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_accounts.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/files/s3_presets.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/l10n/gen/app_localizations_en.dart';
import 'package:player/presentation/screens/sources/add_s3_screen.dart';

import '../../../core/sources/files/fake_backend.dart';
import '../../../core/sources/files/fake_media_names.dart';
import '../../../core/sources/files/files_fixture.dart';
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';

class _Harness {
  _Harness(this.box, this.store, this.storage, this.backend);

  final Box<Map<dynamic, dynamic>> box;
  final InMemorySourceStore store;
  final MockAuthStorage storage;
  final FakeBackend backend;
  final connects = <(S3Location, S3Credentials)>[];
}

int _boxes = 0;
final _l10n = AppLocalizationsEn();

Future<_Harness> _pump(
  WidgetTester tester, {
  String? reauthAccountId,
  _Harness? reuse,
  FileSystemBackend? backend,
}) async {
  var box = reuse?.box;
  if (box == null) {
    final opened = (await tester.runAsync(
      () => Hive.openBox<Map<dynamic, dynamic>>(
        's3_screen_${_boxes++}',
        bytes: Uint8List(0),
      ),
    ))!;
    addTearDown(() => tester.runAsync(opened.close));
    box = opened;
  }
  final h = _Harness(
    box,
    reuse?.store ?? InMemorySourceStore(),
    reuse?.storage ?? MockAuthStorage(),
    FakeBackend({
      '/Films/Amber Tide (2019).mkv': 10,
      '/Shows/Low Orbit/Low Orbit S01E01.mkv': 10,
    }),
  );
  await tester.binding.setSurfaceSize(const Size(900, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (_, _) => const Text('home')),
      GoRoute(
        path: '/add',
        builder: (_, _) => AddS3Screen(reauthAccountId: reauthAccountId),
      ),
      GoRoute(
        path: '/s/:id',
        builder: (_, s) => Text('opened ${s.pathParameters['id']}'),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => h.store),
        sourceSecretsProvider.overrideWithValue(SourceSecrets(h.storage)),
        filesIndexBoxProvider.overrideWithValue(h.box),
        filesProgressStoreProvider.overrideWithValue(
          InMemoryPlaybackProgressStore(),
        ),
        mediaNamesProvider.overrideWithValue(FakeMediaNames()),
        relayTmdbProvider.overrideWithValue(FakeFilesRelay()),
        filesBackendBuilderProvider.overrideWithValue(
          (ref, source) => FakeBackend({}),
        ),
        s3ConnectorProvider.overrideWithValue((location, credentials, client) {
          h.connects.add((location, credentials));
          return backend ?? h.backend;
        }),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  unawaited(router.push('/add'));
  await tester.pumpAndSettle();
  return h;
}

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('s3-provider')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) =>
    tester.enterText(find.byKey(Key(key)), text);

Future<void> _fillAndConnect(
  WidgetTester tester, {
  String bucket = 'reels',
  String prefix = '',
  String secret = 'sk',
}) async {
  await _enter(tester, 's3-bucket', bucket);
  await _enter(tester, 's3-prefix', prefix);
  await _enter(tester, 's3-access-key', 'AK');
  await _enter(tester, 's3-secret-key', secret);
  // Connect enables once the form is complete, on the next frame.
  await tester.pump();
  await tester.tap(find.byKey(const Key('s3-connect')));
  await tester.pumpAndSettle();
}

/// The "Other" preset at [endpoint].
Future<void> _connectOther(
  WidgetTester tester, {
  String endpoint = 'https://s3.example.test',
  String prefix = '',
  String secret = 'sk',
}) async {
  await _choose(tester, 'Other or self-hosted');
  await _enter(tester, 's3-endpoint', endpoint);
  await _fillAndConnect(tester, prefix: prefix, secret: secret);
}

TextField _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key)));

void main() {
  testWidgets('the AWS preset fills region and vhost', (tester) async {
    final h = await _pump(tester);
    await _choose(tester, 'Amazon S3');
    expect(_field(tester, 's3-region').controller!.text, 'us-east-1');
    expect(find.byKey(const Key('s3-endpoint')), findsNothing);

    await _fillAndConnect(tester);
    final (location, creds) = h.connects.single;
    expect(location.style, S3Style.vhost);
    expect(location.endpoint, Uri.parse('https://s3.us-east-1.amazonaws.com'));
    expect(location.region, 'us-east-1');
    expect(location.bucket, 'reels');
    expect((creds.accessKeyId, creds.secretAccessKey), ('AK', 'sk'));
    expect(h.backend.listed, ['/']);
  });

  testWidgets('R2 asks for the account ID', (tester) async {
    final h = await _pump(tester);
    await _choose(tester, 'Cloudflare R2');
    expect(find.byKey(const Key('s3-account-id')), findsOneWidget);
    expect(find.byKey(const Key('s3-region')), findsNothing);

    await _enter(tester, 's3-account-id', 'abc');
    await _fillAndConnect(tester);
    final location = h.connects.single.$1;
    expect(
      location.endpoint,
      Uri.parse('https://abc.r2.cloudflarestorage.com'),
    );
    expect(location.region, 'auto');
    expect(location.style, S3Style.path);
  });

  testWidgets('the style switch overrides the preset', (tester) async {
    final h = await _pump(tester);
    await _choose(tester, 'Amazon S3');
    await tester.tap(find.byKey(const Key('s3-style')));
    await tester.pumpAndSettle();
    await _fillAndConnect(tester);
    expect(h.connects.single.$1.style, S3Style.path);
  });

  testWidgets('a typed AWS endpoint is virtual-hosted', (tester) async {
    final h = await _pump(tester);
    await _connectOther(tester, endpoint: 'https://S3.eu-west-1.amazonaws.com');
    expect(h.connects.single.$1.style, S3Style.vhost);
  });

  testWidgets('any other typed endpoint is path-style', (tester) async {
    final h = await _pump(tester);
    await _connectOther(tester, endpoint: 'http://10.0.0.5:9000');
    expect(h.connects.single.$1.style, S3Style.path);
  });

  testWidgets('the switch wins over a typed AWS endpoint', (tester) async {
    final h = await _pump(tester);
    await _choose(tester, 'Other or self-hosted');
    await _enter(tester, 's3-endpoint', 'https://s3.eu-west-1.amazonaws.com');
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(find.byKey(const Key('s3-style'))).value,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('s3-style')));
    await tester.pumpAndSettle();
    // Retyping the endpoint keeps the viewer's choice.
    await _enter(tester, 's3-endpoint', 'https://s3.us-east-2.amazonaws.com');
    await _fillAndConnect(tester);
    expect(h.connects.single.$1.style, S3Style.path);
  });

  testWidgets('http on a public host is refused without a request', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _connectOther(tester, endpoint: 'http://example.com');
    expect(find.text(_l10n.filesS3ErrorHttpsRequired), findsOneWidget);
    expect(h.connects, isEmpty);
  });

  testWidgets('http on a private host is allowed', (tester) async {
    final h = await _pump(tester);
    await _connectOther(tester, endpoint: '192.168.1.20:9000');
    expect(
      h.connects.single.$1.endpoint,
      Uri.parse('https://192.168.1.20:9000'),
    );
    await tester.pumpWidget(const SizedBox());

    final h2 = await _pump(tester);
    await _connectOther(tester, endpoint: 'http://192.168.1.20:9000');
    expect(
      h2.connects.single.$1.endpoint,
      Uri.parse('http://192.168.1.20:9000'),
    );
  });

  testWidgets('an endpoint with a path is refused without a request', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _connectOther(tester, endpoint: 'https://s3.example.test/x');
    expect(find.text(_l10n.filesS3EndpointInvalid), findsOneWidget);
    expect(h.connects, isEmpty);
  });

  group('each probe failure shows its message', () {
    const host = 's3.example.test';
    final cases = <String, (BackendFailure, String)>{
      'clock': (
        const BackendUnauthorized('x', kS3CodeClockSkew),
        _l10n.filesS3ErrorClock,
      ),
      'region': (
        const BackendUnreachable('x', 301, kS3CodeWrongRegion, 'eu-west-1'),
        _l10n.filesS3ErrorRegion('eu-west-1'),
      ),
      'region unknown': (
        const BackendUnreachable('x', 301, kS3CodeWrongRegion),
        _l10n.filesS3ErrorRegionUnknown,
      ),
      // A public host is refused over http://, so it gets no such advice.
      'tls on a public host': (
        const BackendUnreachable('x', null, kS3CodeTls),
        _l10n.filesS3ErrorTlsPublic(host),
      ),
      'bad keys': (
        const BackendUnauthorized('x', kS3CodeBadKeys),
        _l10n.filesS3ErrorBadKeys,
      ),
      'cannot list': (
        const BackendUnauthorized('x', kS3CodeCannotList),
        _l10n.filesS3ErrorCannotList,
      ),
      'no bucket': (
        const BackendNotFound('x', kS3CodeNoSuchBucket, 'reels'),
        _l10n.filesS3ErrorNoBucket('reels'),
      ),
      'server': (
        const BackendUnreachable(null, 503),
        _l10n.filesS3ErrorServer('503'),
      ),
      'unreachable': (
        const BackendUnreachable('x'),
        _l10n.filesS3ErrorUnreachable(host),
      ),
    };
    for (final MapEntry(key: name, value: (failure, message))
        in cases.entries) {
      testWidgets(name, (tester) async {
        final h = await _pump(tester);
        h.backend.probeFailure = failure;
        await _connectOther(tester);
        expect(find.text(message), findsOneWidget);
        expect(find.byKey(const Key('s3-save')), findsNothing);
        expect((await h.store.load()).accounts, isEmpty);
      });
    }

    testWidgets('tls on a LAN host suggests http://', (tester) async {
      final h = await _pump(tester);
      h.backend.probeFailure = const BackendUnreachable('x', null, kS3CodeTls);
      await _connectOther(tester, endpoint: 'https://192.168.1.20:9000');
      expect(
        find.text(_l10n.filesS3ErrorTls('192.168.1.20:9000')),
        findsOneWidget,
      );
    });
  });

  testWidgets('save stores the account and chosen roots', (tester) async {
    final h = await _pump(tester);
    await _connectOther(tester, prefix: '/media/');

    await tester.tap(find.byKey(const Key('s3-tick-/Films')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('s3-kind-/Films')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('files-kind-movies')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('s3-save')));
    await tester.pumpAndSettle();

    final typed = S3Location(
      endpoint: Uri.parse('https://s3.example.test'),
      bucket: 'reels',
      prefix: 'media/',
      region: 'us-east-1',
      style: S3Style.path,
    );
    final accountId = s3AccountId(typed.toConnectionUri());
    final record = (await h.store.load()).accounts.single;
    expect(record.account.id, accountId);
    final connection = record.servers.single.connections.single.uri;
    expect(connection.toString(), isNot(contains('sk')));
    final secret = await h.storage.read(
      '${record.account.storageNamespace}/account_token',
    );
    final creds = S3Credentials.fromJson(secret!);
    expect((creds.accessKeyId, creds.secretAccessKey), ('AK', 'sk'));

    final roots = FileLibraryIndex(h.box, accountId: accountId).roots();
    expect(roots.single.path, '/Films');
    expect(roots.single.kind, FilesLibraryKind.movies);
    expect(find.text('opened $accountId:owner:$accountId'), findsOneWidget);
  });

  testWidgets('S3 folders that differ by a trailing slash stay apart', (
    tester,
  ) async {
    final h = await _pump(tester, backend: _SlashBackend());
    await _connectOther(tester, prefix: 'media');

    // Open `/Films`: its own row and the folder `/Films/` (key
    // `media/Films//`) inside it are two rows with two keys.
    await tester.tap(find.byKey(const ValueKey('s3-folder-/Films')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('s3-folder-/Films')), findsOneWidget);
    expect(find.byKey(const ValueKey('s3-folder-/Films/')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('s3-tick-/Films/')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Checkbox>(find.byKey(const ValueKey('s3-tick-/Films')))
          .value,
      isFalse,
    );

    // Into `/Films/` and back up lands in `/Films`, not the bucket root.
    // Its name, not the row's centre, which the kind picker now covers.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('s3-folder-/Films/')),
        matching: find.text('/'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('s3-dir'))).data,
      '/Films/',
    );
    await tester.tap(find.byKey(const Key('s3-up')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('s3-dir'))).data, '/Films');

    await tester.tap(find.byKey(const Key('s3-save')));
    await tester.pumpAndSettle();
    final accountId = (await h.store.load()).accounts.single.account.id;
    expect(
      FileLibraryIndex(h.box, accountId: accountId).roots().map((r) => r.path),
      ['/Films/'],
    );
  });

  testWidgets('sign in again locks the location and saves the keys', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _connectOther(
      tester,
      endpoint: 'https://s3.example.test:9000',
      prefix: 'media',
    );
    await tester.tap(find.byKey(const Key('s3-tick-/Films')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('s3-save')));
    await tester.pumpAndSettle();
    final saved = (await h.store.load()).accounts.single;
    final accountId = saved.account.id;
    // The keys stopped working: sign in again changes only them.
    await h.store.putAccount(
      saved.copyWith(account: saved.account.copyWith(needsReauth: true)),
    );

    await tester.pumpWidget(const SizedBox());
    final again = await _pump(tester, reauthAccountId: accountId, reuse: h);
    for (final (key, text) in [
      ('s3-endpoint', 'https://s3.example.test:9000'),
      ('s3-region', 'us-east-1'),
      ('s3-bucket', 'reels'),
      ('s3-prefix', 'media'),
    ]) {
      expect(_field(tester, key).controller!.text, text, reason: key);
      expect(_field(tester, key).readOnly, isTrue, reason: key);
    }
    expect(_field(tester, 's3-access-key').readOnly, isFalse);
    expect(_field(tester, 's3-secret-key').readOnly, isFalse);
    expect(
      tester
          .widget<DropdownButtonFormField<S3Preset>>(
            find.byKey(const Key('s3-provider')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('s3-style')))
          .onChanged,
      isNull,
    );

    await _enter(tester, 's3-access-key', 'AK2');
    await _enter(tester, 's3-secret-key', 'new');
    await tester.pump();
    await tester.tap(find.byKey(const Key('s3-connect')));
    await tester.pumpAndSettle();

    expect(
      again.connects.single.$1.toConnectionUri(),
      S3Location.fromConnectionUri(
        (await h.store.load())
            .accounts
            .single
            .servers
            .single
            .connections
            .single
            .uri,
      )!.toConnectionUri(),
    );
    final record = (await h.store.load()).accounts.single;
    expect(record.account.id, accountId);
    final secret = await h.storage.read(
      '${record.account.storageNamespace}/account_token',
    );
    expect(S3Credentials.fromJson(secret!).secretAccessKey, 'new');
    expect(FileLibraryIndex(h.box, accountId: accountId).roots(), hasLength(1));
    expect(find.text('opened $accountId:owner:$accountId'), findsOneWidget);
  });

  /// Saves a bucket with the folder `/Films`, then reopens it from its
  /// management screen.
  Future<(_Harness, String)> reopen(WidgetTester tester) async {
    final h = await _pump(tester);
    await _connectOther(tester, prefix: 'media');
    await tester.tap(find.byKey(const Key('s3-tick-/Films')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('s3-save')));
    await tester.pumpAndSettle();
    final accountId = (await h.store.load()).accounts.single.account.id;
    await tester.pumpWidget(const SizedBox());
    return (
      await _pump(tester, reauthAccountId: accountId, reuse: h),
      accountId,
    );
  }

  testWidgets('change keys or folders reaches the folders', (tester) async {
    final (h, accountId) = await reopen(tester);
    expect(_field(tester, 's3-bucket').readOnly, isTrue);
    await _enter(tester, 's3-access-key', 'AK2');
    await _enter(tester, 's3-secret-key', 'newer');
    await tester.pump();
    await tester.tap(find.byKey(const Key('s3-connect')));
    await tester.pumpAndSettle();

    // The folders, with the location still locked.
    expect(find.byKey(const Key('s3-folder-picker')), findsOneWidget);
    expect(_field(tester, 's3-bucket').readOnly, isTrue);
    await tester.tap(find.byKey(const Key('s3-tick-/Shows')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('s3-save')));
    await tester.pumpAndSettle();

    final record = (await h.store.load()).accounts.single;
    expect(record.account.id, accountId);
    final secret = await h.storage.read(
      '${record.account.storageNamespace}/account_token',
    );
    expect(S3Credentials.fromJson(secret!).secretAccessKey, 'newer');
    expect(
      FileLibraryIndex(h.box, accountId: accountId).roots().map((r) => r.path),
      unorderedEquals(['/Films', '/Shows']),
    );
    expect(find.text('opened $accountId:owner:$accountId'), findsOneWidget);
  });

  testWidgets('leaving during the probe saves nothing and does not throw', (
    tester,
  ) async {
    final (h, accountId) = await reopen(tester);
    final saved = (await h.store.load()).accounts.single;
    await h.store.putAccount(
      saved.copyWith(account: saved.account.copyWith(needsReauth: true)),
    );
    // Reopen so the screen reads needsReauth.
    await tester.pumpWidget(const SizedBox());
    final again = await _pump(tester, reauthAccountId: accountId, reuse: h);
    final hold = Completer<void>();
    again.backend.probeHold = hold;
    await _enter(tester, 's3-access-key', 'AK2');
    await _enter(tester, 's3-secret-key', 'abandoned');
    await tester.pump();
    await tester.tap(find.byKey(const Key('s3-connect')));
    await tester.pump();

    final logged = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logged.add(message);
    };
    addTearDown(() => debugPrint = original);
    await tester.pumpWidget(const SizedBox());
    hold.complete();
    await tester.pumpAndSettle();
    debugPrint = original;

    expect(tester.takeException(), isNull);
    // A save after the screen went would call setState on a disposed state,
    // which the connect handler swallows and logs.
    expect(logged.where((l) => l.startsWith('[AddS3]')), isEmpty);
    final record = (await h.store.load()).accounts.single;
    final secret = await h.storage.read(
      '${record.account.storageNamespace}/account_token',
    );
    expect(S3Credentials.fromJson(secret!).secretAccessKey, 'sk');
  });
}

/// A bucket under `media/` holding the keys `media/Films/a.mkv` and
/// `media/Films//b.mkv`: the folder `/Films`, and inside it the folder
/// `/Films/`, as [S3Backend] lists them.
class _SlashBackend implements FileSystemBackend {
  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  FileEntry _dir(String path, String name) =>
      FileEntry(path: path, name: name, isDir: true, size: 0, modified: _epoch);

  @override
  Future<List<FileEntry>> list(String dir) async => switch (dir) {
    '/' || '' => [_dir('/Films', 'Films')],
    '/Films' => [_dir('/Films/', '/')],
    _ => const [],
  };

  @override
  Future<FileEntry?> stat(String path) async => null;

  @override
  Future<PlayableFile> playable(String path) async =>
      const PlayableFile(url: 'https://example.invalid/x');

  @override
  Future<void> probe() async {}
}
