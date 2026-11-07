import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/backend/webdav_backend.dart';

WebDavBackend backend(MockClient client) => WebDavBackend(
      base: Uri.parse('https://dav.example.com/media/'),
      user: 'user',
      password: 'pass',
      client: client,
    );

String fixture() =>
    File('test/fixtures/files/webdav_multistatus.xml').readAsStringSync();

MockClient okClient({void Function(http.Request)? onRequest}) =>
    MockClient((req) async {
      onRequest?.call(req);
      return http.Response(fixture(), 207);
    });

void main() {
  test('propfind_sends_depth_1_and_basic_auth', () async {
    late http.Request seen;
    await backend(okClient(onRequest: (r) => seen = r)).list('/media/Movies/');
    expect(seen.method, 'PROPFIND');
    expect(seen.headers['Depth'], '1');
    expect(seen.headers['Authorization'], 'Basic dXNlcjpwYXNz');
    expect(seen.url.path, '/media/Movies/');
  });

  test('parses_multistatus_and_skips_the_listed_dir_itself', () async {
    final entries = await backend(okClient()).list('/media/Movies');
    expect(entries.map((e) => e.name), [
      'Extras',
      'Night Train #2 (2011).mkv',
      'Café Lumière (2015).mkv',
      'Harbor Lights.mp4',
    ]);
    expect(entries[0].isDir, isTrue);
    expect(entries[0].size, 0);
    expect(entries[1].path, '/media/Movies/Night Train #2 (2011).mkv');
    expect(entries[1].size, 1048576);
    expect(entries[1].modified, DateTime.utc(2026, 11, 1, 12));
    expect(entries[2].path, '/media/Movies/Café Lumière (2015).mkv');
    expect(entries[3].path, '/media/Movies/Harbor Lights.mp4');
    expect(entries[3].modified,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
  });

  test('playable_reencodes_the_path_and_carries_auth', () async {
    final p = await backend(okClient())
        .playable('/media/Movies/Night Train #2 (2011).mkv');
    expect(p.url, endsWith('/Night%20Train%20%232%20(2011).mkv'));
    expect(p.url, startsWith('https://dav.example.com/'));
    expect(p.headers['Authorization'], 'Basic dXNlcjpwYXNz');
  });

  test('non_utf8_percent_name_lists_and_round_trips_through_playable',
      () async {
    const xml = '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
        '<D:response><D:href>/media/Movies/</D:href><D:propstat><D:prop>'
        '<D:resourcetype><D:collection/></D:resourcetype></D:prop>'
        '</D:propstat></D:response>'
        '<D:response><D:href>/media/Movies/Caf%E9%20Nuit%20(2012).mkv</D:href>'
        '<D:propstat><D:prop><D:resourcetype/>'
        '<D:getcontentlength>10</D:getcontentlength></D:prop></D:propstat>'
        '</D:response></D:multistatus>';
    final b = backend(MockClient((_) async => http.Response(xml, 207)));
    final entries = await b.list('/media/Movies/');
    expect(entries, hasLength(1));
    final p = await b.playable(entries.single.path);
    expect(
      p.url,
      'https://dav.example.com/media/Movies/Caf%E9%20Nuit%20(2012).mkv',
    );
  });

  test('status_401_throws_unauthorized', () {
    final b = backend(MockClient((_) async => http.Response('', 401)));
    expect(b.list('/media/'), throwsA(isA<BackendUnauthorized>()));
  });

  test('status_404_throws_not_found_and_stat_is_null', () async {
    final b = backend(MockClient((_) async => http.Response('', 404)));
    expect(b.list('/media/'), throwsA(isA<BackendNotFound>()));
    expect(await b.stat('/media/x.mkv'), isNull);
  });

  test('status_500_throws_unreachable', () {
    final b = backend(MockClient((_) async => http.Response('', 500)));
    expect(b.probe(), throwsA(isA<BackendUnreachable>()));
  });

  test('socket_error_throws_unreachable', () {
    final b = backend(
      MockClient((_) async => throw const SocketException('no route')),
    );
    expect(b.list('/media/'), throwsA(isA<BackendUnreachable>()));
  });

  test('client_exception_and_timeout_throw_unreachable', () {
    expect(
      backend(MockClient((_) async => throw http.ClientException('x'))).probe(),
      throwsA(isA<BackendUnreachable>()),
    );
    expect(
      backend(MockClient((_) async => throw TimeoutException('x'))).probe(),
      throwsA(isA<BackendUnreachable>()),
    );
  });

  test('probe_is_propfind_depth_0_on_the_base_path', () async {
    late http.Request seen;
    await backend(okClient(onRequest: (r) => seen = r)).probe();
    expect(seen.headers['Depth'], '0');
    expect(seen.url.path, '/media/');
  });
}
