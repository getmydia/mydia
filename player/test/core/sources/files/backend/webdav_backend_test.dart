import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/backend/webdav_backend.dart';
import 'package:player/core/sources/files/files_accounts.dart' show webDavBase;

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

  test('webdav_server_rs_reply_lists_its_video', () async {
    // webdav-server-rs, as captured: parentheses escaped in hrefs the
    // client sent raw, a split 200/404 propstat on the folder, and both D:
    // and d: bound to DAV:.
    const xml = '<D:multistatus xmlns:D="DAV:"><D:response>'
        '<D:href>/media/Movies/Amber%20Tide%20%282019%29/</D:href>'
        '<D:propstat><D:prop><d:resourcetype xmlns:d="DAV:"><D:collection>'
        '</D:collection></d:resourcetype><D:getlastmodified>Tue, 20 Oct 2026 '
        '12:29:59 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK'
        '</D:status></D:propstat><D:propstat><D:prop><D:getcontentlength>'
        '</D:getcontentlength></D:prop><D:status>HTTP/1.1 404 Not Found'
        '</D:status></D:propstat></D:response><D:response>'
        '<D:href>/media/Movies/Amber%20Tide%20%282019%29/'
        'Amber.Tide.2019.1080p.BluRay.x264.mkv</D:href><D:propstat><D:prop>'
        '<d:resourcetype xmlns:d="DAV:"></d:resourcetype><D:getcontentlength>'
        '9036244507</D:getcontentlength><D:getlastmodified>Tue, 20 Oct 2026 '
        '12:30:59 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK'
        '</D:status></D:propstat></D:response></D:multistatus>';
    late http.Request seen;
    final entries = await backend(MockClient((request) async {
      seen = request;
      return http.Response(xml, 207);
    })).list('/media/Movies/Amber Tide (2019)');
    expect(
        Uri.decodeComponent(seen.url.path), '/media/Movies/Amber Tide (2019)/');
    expect(entries, hasLength(1));
    final video = entries.single;
    expect(video.name, 'Amber.Tide.2019.1080p.BluRay.x264.mkv');
    expect(video.isDir, isFalse);
    expect(video.unreadable, isFalse);
    expect(video.size, 9036244507);
  });

  test('a_listing_logs_its_shape_not_its_content', () async {
    // Logs are shared; a reply can carry signed URLs.
    const xml = '<D:multistatus xmlns:D="DAV:"><D:response>'
        '<D:href>/media/Movies/</D:href><D:propstat><D:prop><D:resourcetype>'
        '<D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK'
        '</D:status></D:propstat></D:response><D:response>'
        '<D:href>https://dav.example.com/media/Movies/a.mkv?sig=SECRET</D:href>'
        '<D:propstat><D:prop><D:resourcetype/><D:getcontentlength>5'
        '</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status>'
        '</D:propstat></D:response></D:multistatus>';
    final logged = <String>[];
    final original = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logged.add(m ?? '');
    addTearDown(() => debugPrint = original);

    final b = backend(MockClient((_) async => http.Response(xml, 207)));
    await b.list('/media/Movies');
    await b.list('/media/Movies');

    expect(logged.where((l) => l.contains('PROPFIND')), hasLength(1));
    expect(logged.single, contains('1 absolute hrefs'));
    expect(logged.join('\n'), isNot(contains('SECRET')));
  });

  test('a_child_outside_the_folder_is_counted_without_its_path', () async {
    String reply(String self, String child) =>
        '<D:multistatus xmlns:D="DAV:"><D:response><D:href>$self</D:href>'
        '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
        '</D:response><D:response><D:href>$child</D:href><D:propstat>'
        '<D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK'
        '</D:status></D:propstat></D:response></D:multistatus>';
    final logged = <String>[];
    final original = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logged.add(m ?? '');
    addTearDown(() => debugPrint = original);

    // The share's root holds its children: no warning.
    await backend(
            MockClient((_) async => http.Response(reply('/', '/a.mkv'), 207)))
        .list('/');
    expect(logged.where((l) => l.contains('outside')), isEmpty);

    await backend(MockClient((_) async => http.Response(
            reply('/media/Movies/', '/elsewhere/a.mkv?sig=SECRET'), 207)))
        .list('/media/Movies');
    expect(logged.where((l) => l.contains('1 of 1 entries outside')),
        hasLength(1));
    expect(logged.join('\n'), isNot(contains('SECRET')));
  });

  test('a_relative_href_query_stays_out_of_the_path', () async {
    // So a signature never reaches the paths the scanner logs.
    const xml = '<D:multistatus xmlns:D="DAV:"><D:response>'
        '<D:href>/media/Movies/</D:href><D:propstat><D:prop><D:resourcetype>'
        '<D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK'
        '</D:status></D:propstat></D:response><D:response>'
        '<D:href>/media/Movies/Sub/?sig=SECRET&amp;v=1</D:href><D:propstat>'
        '<D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>'
        '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
        '</D:multistatus>';
    final entries =
        await backend(MockClient((_) async => http.Response(xml, 207)))
            .list('/media/Movies');
    expect(entries.single.path, '/media/Movies/Sub/');
    expect(entries.single.isDir, isTrue);
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

  test('an_ipv6_host_keeps_its_brackets', () async {
    late http.Request seen;
    final b = WebDavBackend(
      base: Uri.parse('http://[fd00::1]:8080/media/'),
      user: 'user',
      password: 'pass',
      client: okClient(onRequest: (r) => seen = r),
    );
    final p = await b.playable('/media/A Film.mkv');
    expect(p.url, 'http://[fd00::1]:8080/media/A%20Film.mkv');
    await b.probe();
    expect(seen.url.host, 'fd00::1');
    expect(seen.url.port, 8080);
  });

  test('an_ipv6_share_url_normalizes_to_a_parsable_base', () {
    final base = webDavBase(Uri.parse('http://[FD00::1]:8080/dav/'));
    expect(base.host, 'fd00::1');
    expect(base.port, 8080);
    expect(base.path, '/dav');
  });

  test('an_encoded_base_path_is_probed_once_encoded', () async {
    late http.Request seen;
    await WebDavBackend(
      base: Uri.parse('https://dav.example.com/my%20share/'),
      user: 'user',
      password: 'pass',
      client: okClient(onRequest: (r) => seen = r),
    ).probe();
    expect(seen.url.path, '/my%20share/');
  });

  test('well_formed_xml_that_is_not_a_multistatus_is_unreachable', () {
    final b = backend(MockClient((_) async => http.Response(
        '<?xml version="1.0"?><html><body>Sign in</body></html>', 200)));
    expect(b.list('/media/'), throwsA(isA<BackendUnreachable>()));
  });

  test('a_denied_file_is_listed_unreadable_and_the_rest_lists', () async {
    const xml = '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
        '<D:response><D:href>/media/</D:href><D:propstat><D:prop>'
        '<D:resourcetype><D:collection/></D:resourcetype></D:prop>'
        '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
        '<D:response><D:href>/media/Locked.mkv</D:href><D:propstat><D:prop>'
        '<D:resourcetype/></D:prop>'
        '<D:status>HTTP/1.1 403 Forbidden</D:status></D:propstat>'
        '</D:response>'
        '<D:response><D:href>/media/Gone.mkv</D:href>'
        '<D:status>HTTP/1.1 403 Forbidden</D:status></D:response>'
        '<D:response><D:href>/media/Open.mkv</D:href><D:propstat><D:prop>'
        '<D:resourcetype/><D:getcontentlength>5</D:getcontentlength>'
        '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
        '</D:response></D:multistatus>';
    final b = backend(MockClient((_) async => http.Response(xml, 207)));
    final entries = await b.list('/media/');
    expect(
      [for (final e in entries) (e.name, e.unreadable)],
      [('Locked.mkv', true), ('Gone.mkv', true), ('Open.mkv', false)],
    );
  });

  test('a_denied_folder_is_listed_unreadable', () async {
    const xml = '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
        '<D:response><D:href>/media/Private/</D:href>'
        '<D:status>HTTP/1.1 403 Forbidden</D:status></D:response>'
        '<D:response><D:href>/media/Typed</D:href><D:propstat><D:prop>'
        '<D:resourcetype><D:collection/></D:resourcetype></D:prop>'
        '<D:status>HTTP/1.1 403 Forbidden</D:status></D:propstat>'
        '</D:response></D:multistatus>';
    final b = backend(MockClient((_) async => http.Response(xml, 207)));
    final entries = await b.list('/media/');
    expect(
      [for (final e in entries) (e.name, e.isDir, e.unreadable)],
      [('Private', true, true), ('Typed', true, true)],
    );
  });

  test('a_404_propstat_for_other_properties_still_lists', () async {
    const xml = '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
        '<D:response><D:href>/media/A.mkv</D:href>'
        '<D:propstat><D:prop><D:resourcetype/>'
        '<D:getcontentlength>5</D:getcontentlength></D:prop>'
        '<D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
        '<D:propstat><D:prop><D:getlastmodified/></D:prop>'
        '<D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>'
        '</D:response></D:multistatus>';
    final b = backend(MockClient((_) async => http.Response(xml, 207)));
    final entries = await b.list('/media/');
    expect(entries.single.name, 'A.mkv');
    expect(entries.single.size, 5);
  });

  test('probe_is_propfind_depth_0_on_the_base_path', () async {
    late http.Request seen;
    await backend(okClient(onRequest: (r) => seen = r)).probe();
    expect(seen.headers['Depth'], '0');
    expect(seen.url.path, '/media/');
  });

  group('collections_are_requested_with_a_trailing_slash', () {
    WebDavBackend slashless(List<http.Request> seen) => WebDavBackend(
          base: Uri.parse('https://dav.example.com/media'),
          user: 'user',
          password: 'pass',
          client: okClient(onRequest: seen.add),
        );

    test('probe', () async {
      final seen = <http.Request>[];
      await slashless(seen).probe();
      expect(seen.single.url.path, '/media/');
    });

    test('root_list', () async {
      final seen = <http.Request>[];
      await slashless(seen).list('/media');
      expect(seen.single.url.path, '/media/');
    });

    test('subdirectory_list', () async {
      final seen = <http.Request>[];
      await slashless(seen).list('/media/Movies/Café Nights');
      expect(seen.single.url.path, '/media/Movies/Caf%C3%A9%20Nights/');
    });

    test('empty_base_path', () async {
      final seen = <http.Request>[];
      await WebDavBackend(
        base: Uri.parse('https://dav.example.com'),
        user: 'user',
        password: 'pass',
        client: okClient(onRequest: seen.add),
      ).probe();
      expect(seen.single.url.path, '/');
    });
  });

  group('a_server_that_never_answers_times_out_as_unreachable', () {
    WebDavBackend hung(MockClient client) => WebDavBackend(
          base: Uri.parse('https://dav.example.com/media/'),
          user: 'user',
          password: 'pass',
          client: client,
          timeout: const Duration(milliseconds: 50),
        );

    test('no_response_headers', () async {
      final b = hung(MockClient((_) => Completer<http.Response>().future));
      await expectLater(b.probe(), throwsA(isA<BackendUnreachable>()));
      await expectLater(b.list('/media/'), throwsA(isA<BackendUnreachable>()));
    });

    test('headers_then_a_body_that_never_ends', () async {
      final b = hung(MockClient.streaming((_, __) async =>
          http.StreamedResponse(StreamController<List<int>>().stream, 207)));
      await expectLater(b.probe(), throwsA(isA<BackendUnreachable>()));
    });

    test('defaults_to_twenty_seconds', () {
      expect(kWebDavTimeout, const Duration(seconds: 20));
    });
  });
}
