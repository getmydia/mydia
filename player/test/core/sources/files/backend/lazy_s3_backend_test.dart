import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_providers.dart';

final _connection =
    Uri.parse('s3+https://s3.example.test/bkt/media/?region=r&style=path');

const _listing = '<?xml version="1.0" encoding="UTF-8"?>'
    '<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>';

const _creds = S3Credentials(accessKeyId: 'AKID', secretAccessKey: 'secret');

void main() {
  test('missing_credentials_are_refused_and_not_cached', () async {
    String? stored;
    final backend = LazyS3Backend(
      connection: _connection,
      credentials: () async => stored,
      client: MockClient((_) async => http.Response(_listing, 200)),
    );
    await expectLater(backend.probe(), throwsA(isA<BackendUnauthorized>()));
    stored = _creds.toJson();
    await backend.probe();
  });

  test('unreadable_credentials_are_refused', () async {
    final backend = LazyS3Backend(
      connection: _connection,
      credentials: () async => '{"user":"u","password":"p"}',
      client: MockClient((_) async => http.Response(_listing, 200)),
    );
    await expectLater(backend.probe(), throwsA(isA<BackendUnauthorized>()));
  });

  test('the_first_call_builds_the_backend_once', () async {
    var reads = 0;
    final requests = <Uri>[];
    final backend = LazyS3Backend(
      connection: _connection,
      credentials: () async {
        reads++;
        return _creds.toJson();
      },
      client: MockClient((r) async {
        requests.add(r.url);
        return http.Response(_listing, 200);
      }),
    );
    await backend.probe();
    await backend.list('/');
    final playable = await backend.playable('/Films/Copper Valley (2018).mkv');
    expect(reads, 1);
    expect(requests, hasLength(2));
    expect(requests.first.host, 's3.example.test');
    expect(requests.first.path, '/bkt');
    expect(playable.url,
        startsWith('https://s3.example.test/bkt/media/Films/Copper'));
    expect(playable.url, isNot(contains('secret')));
  });

  test('a_refused_call_rereads_the_credentials', () async {
    var reads = 0;
    var status = 403;
    final backend = LazyS3Backend(
      connection: _connection,
      credentials: () async {
        reads++;
        return _creds.toJson();
      },
      client: MockClient((_) async => status == 200
          ? http.Response(_listing, 200)
          : http.Response(
              '<Error><Code>InvalidAccessKeyId</Code></Error>', status)),
    );
    await expectLater(backend.probe(), throwsA(isA<BackendUnauthorized>()));
    status = 200;
    await backend.probe();
    expect(reads, 2);
  });

  test('close_closes_the_client_it_made_and_not_a_given_one', () {
    final made = _TrackedClient();
    LazyS3Backend(
      connection: _connection,
      credentials: () async => _creds.toJson(),
      newClient: () => made,
    ).close();
    expect(made.closed, isTrue);

    final given = _TrackedClient();
    LazyS3Backend(
      connection: _connection,
      credentials: () async => _creds.toJson(),
      client: given,
      newClient: () => fail('a given client is used as is'),
    ).close();
    expect(given.closed, isFalse);
  });

  test('a_damaged_connection_is_unreachable', () async {
    final backend = LazyS3Backend(
      connection: Uri.parse('https://s3.example.test/bkt'),
      credentials: () async => _creds.toJson(),
      client: MockClient((_) async => http.Response(_listing, 200)),
    );
    await expectLater(backend.probe(), throwsA(isA<BackendUnreachable>()));
  });
}

/// Records [close]; answers nothing a test reaches.
class _TrackedClient extends MockClient {
  _TrackedClient() : super((_) async => http.Response('', 500));

  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}
