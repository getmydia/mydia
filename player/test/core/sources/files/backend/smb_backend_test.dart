import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/backend/smb_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/smb_native.dart';

import '../fake_smb_native.dart';

const _target = SmbTarget(host: 'nas.local', port: 445, share: 'media');
const _creds = SmbCredentials(user: 'quill', password: 'pw');

void main() {
  late FakeSmbNative native;

  setUp(() {
    native = FakeSmbNative()
      ..addFile('media', '/Films/Copper Valley (2018).mkv', size: 7)
      ..addDir('media', '/Shows');
  });

  SmbBackend backend() => SmbBackend(
        native: native,
        accountId: 'sabc',
        target: _target,
        credentials: _creds,
      );

  test('list_and_stat_pass_native_entries_through', () async {
    final b = backend();
    final entries = await b.list('/Films');
    expect(entries.single.path, '/Films/Copper Valley (2018).mkv');
    expect(entries.single.size, 7);
    final root = await b.list('/');
    expect(root.map((e) => e.path), unorderedEquals(['/Films', '/Shows']));
    expect((await b.stat('/Films'))?.isDir, isTrue);
    expect(await b.stat('/missing'), isNull);
  });

  test('playable_is_the_loopback_url_with_no_headers', () async {
    final p = await backend().playable('/Films/Copper Valley (2018).mkv');
    expect(p.url, 'http://127.0.0.1:1/smb/0');
    expect(p.headers, isEmpty);
    expect(native.opens, [('sabc', '/Films/Copper Valley (2018).mkv')]);
  });

  test('probe_checks_the_share_root', () async {
    await backend().probe();
    native.failure = const BackendUnauthorized();
    await expectLater(backend().probe(), throwsA(isA<BackendUnauthorized>()));
  });

  group('LazySmbBackend', () {
    LazySmbBackend lazy(Future<String?> Function() credentials) =>
        LazySmbBackend(
          native: native,
          accountId: 'sabc',
          target: _target,
          credentials: credentials,
        );

    test('missing_or_unreadable_credentials_are_refused', () async {
      String? stored;
      final b = lazy(() async => stored);
      await expectLater(b.probe(), throwsA(isA<BackendUnauthorized>()));
      stored = 'not json';
      await expectLater(b.probe(), throwsA(isA<BackendUnauthorized>()));
      stored = _creds.toJson();
      await b.probe();
    });

    test('a_refused_call_rereads_the_credentials', () async {
      var reads = 0;
      final b = lazy(() async {
        reads++;
        return _creds.toJson();
      });
      await b.probe();
      await b.probe();
      expect(reads, 1);

      native.failure = const BackendUnauthorized();
      await expectLater(b.list('/'), throwsA(isA<BackendUnauthorized>()));
      native.failure = null;
      await b.list('/');
      expect(reads, 2);
    });

    test('close_reaches_close_account', () async {
      final b = lazy(() async => _creds.toJson());
      await b.close();
      expect(native.closedAccounts, ['sabc']);
    });
  });
}
