import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/domain/sources/source_error.dart';

Matcher failsWith(SourceErrorKind kind) =>
    throwsA(isA<SourceException>().having((e) => e.kind, 'kind', kind));

void main() {
  final url = Uri.parse('https://plex.test:32400/library/sections');

  test('decodes JSON and forwards headers and body', () async {
    late http.Request seen;
    final http_ = SourceHttp(client: MockClient((request) async {
      seen = request;
      return http.Response('{"ok":true}', 200);
    }));
    final json = await http_
        .json('POST', url, headers: {'X-Plex-Token': 't'}, body: {'a': 1});
    expect(json, {'ok': true});
    expect(seen.headers['X-Plex-Token'], 't');
    expect(seen.headers['Content-Type'], startsWith('application/json'));
    expect(seen.body, '{"a":1}');
  });

  test('maps status codes', () async {
    for (final (code, kind) in [
      (401, SourceErrorKind.unauthorized),
      (403, SourceErrorKind.unauthorized),
      (404, SourceErrorKind.notFound),
      (500, SourceErrorKind.server),
    ]) {
      final http_ =
          SourceHttp(client: MockClient((_) async => http.Response('', code)));
      await expectLater(http_.send('GET', url), failsWith(kind));
    }
  });

  test('a status in passThrough is returned, others still fail', () async {
    final http_ = SourceHttp(
        client: MockClient((_) async => http.Response('{"errors":[]}', 422)));
    expect(
        await http_.json('GET', url, passThrough: const {422}), {'errors': []});
    await expectLater(
        http_.json('GET', url), failsWith(SourceErrorKind.server));
    await expectLater(http_.json('GET', url, passThrough: const {400}),
        failsWith(SourceErrorKind.server));
  });

  test('a transport failure or a timeout is unreachable', () async {
    final refused = SourceHttp(client: MockClient((_) async {
      throw http.ClientException('Connection refused');
    }));
    await expectLater(
        refused.send('GET', url), failsWith(SourceErrorKind.unreachable));

    final slow = SourceHttp(client: MockClient((_) async {
      await Future<void>.delayed(const Duration(seconds: 1));
      return http.Response('', 200);
    }));
    await expectLater(
      slow.send('GET', url, timeout: const Duration(milliseconds: 10)),
      failsWith(SourceErrorKind.unreachable),
    );
  });

  test('a body that is not JSON is a server error', () async {
    final http_ = SourceHttp(
        client: MockClient((_) async => http.Response('<html>', 200)));
    await expectLater(
        http_.json('GET', url), failsWith(SourceErrorKind.server));
  });
}
