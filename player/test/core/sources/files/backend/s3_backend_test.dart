import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/backend/s3_backend.dart';
import 'package:player/core/sources/files/backend/s3_errors.dart';

final _pathLocation = S3Location(
  endpoint: Uri.parse('https://h:9000'),
  bucket: 'bkt',
  prefix: 'media/',
  region: 'us-east-1',
  style: S3Style.path,
);

final _vhostLocation = S3Location(
  endpoint: Uri.parse('https://s3.us-east-1.amazonaws.com'),
  bucket: 'bkt',
  prefix: 'media/',
  region: 'us-east-1',
  style: S3Style.vhost,
);

S3Backend backend(
  http.Client client, {
  S3Location? location,
  Duration timeout = kS3Timeout,
}) =>
    S3Backend(
      location: location ?? _pathLocation,
      accessKeyId: 'AKIDEXAMPLE',
      secretAccessKey: 'secret',
      client: client,
      clock: () => DateTime.utc(2026, 11, 14, 12),
      timeout: timeout,
    );

String listing({
  List<String> prefixes = const [],
  List<String> contents = const [],
  bool truncated = false,
  String? token,
}) {
  final keyCount = prefixes.length + contents.length;
  return '<?xml version="1.0" encoding="UTF-8"?>'
      '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
      '<Name>bkt</Name><KeyCount>$keyCount</KeyCount>'
      '<IsTruncated>$truncated</IsTruncated>'
      '${token == null ? '' : '<NextContinuationToken>$token</NextContinuationToken>'}'
      '${contents.join()}'
      '${prefixes.map((p) => '<CommonPrefixes><Prefix>$p</Prefix></CommonPrefixes>').join()}'
      '</ListBucketResult>';
}

String object(
  String key, {
  int size = 10,
  String modified = '2026-01-02T03:04:05.000Z',
  String storageClass = 'STANDARD',
}) =>
    '<Contents><Key>$key</Key><LastModified>$modified</LastModified>'
    '<Size>$size</Size><StorageClass>$storageClass</StorageClass></Contents>';

String xmlEscape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

void main() {
  test('lists folders and files under the prefix', () async {
    late http.Request seen;
    final entries = await backend(MockClient((r) async {
      seen = r;
      return http.Response(
          listing(
              prefixes: ['media/Movies/'], contents: [object('media/a.mkv')]),
          200);
    })).list('/');

    expect(seen.method, 'GET');
    expect(seen.url.queryParameters, {
      'list-type': '2',
      'delimiter': '/',
      'prefix': 'media/',
      'max-keys': '1000',
    });
    expect(seen.headers['authorization'], startsWith('AWS4-HMAC-SHA256 '));
    expect(entries, hasLength(2));
    final dir = entries.firstWhere((e) => e.isDir);
    expect(dir.path, '/Movies');
    expect(dir.name, 'Movies');
    expect(dir.size, 0);
    expect(dir.modified, _epoch);
    final file = entries.firstWhere((e) => !e.isDir);
    expect(file.path, '/a.mkv');
    expect(file.name, 'a.mkv');
    expect(file.size, 10);
    expect(file.modified, DateTime.utc(2026, 1, 2, 3, 4, 5));
    expect(file.unreadable, isFalse);
  });

  test('lists a subfolder under its key prefix', () async {
    late http.Request seen;
    final entries = await backend(MockClient((r) async {
      seen = r;
      return http.Response(
          listing(contents: [object('media/Movies/x.mkv')]), 200);
    })).list('/Movies');
    expect(seen.url.queryParameters['prefix'], 'media/Movies/');
    expect(entries.single.path, '/Movies/x.mkv');
  });

  test('follows continuation tokens', () async {
    final seen = <http.Request>[];
    final entries = await backend(MockClient((r) async {
      seen.add(r);
      if (seen.length == 1) {
        return http.Response(
            listing(
                contents: [object('media/a.mkv')],
                truncated: true,
                token: 't1'),
            200);
      }
      return http.Response(listing(contents: [object('media/b.mkv')]), 200);
    })).list('/');

    expect(seen, hasLength(2));
    expect(
        seen[0].url.queryParameters.containsKey('continuation-token'), isFalse);
    expect(seen[1].url.queryParameters['continuation-token'], 't1');
    expect(entries.map((e) => e.path), ['/a.mkv', '/b.mkv']);
  });

  test('a truncated listing without a token fails', () async {
    // A V1-style answer: NextMarker, no NextContinuationToken.
    final seen = <http.Request>[];
    await expectLater(
      backend(MockClient((r) async {
        seen.add(r);
        return http.Response(
            listing(contents: [object('media/a.mkv')], truncated: true), 200);
      })).list('/'),
      throwsA(isA<BackendUnreachable>()
          .having((e) => e.message, 'message', contains('incomplete listing'))),
    );
    expect(seen, hasLength(1));
  });

  test('a repeated continuation token fails', () async {
    final seen = <http.Request>[];
    await expectLater(
      backend(MockClient((r) async {
        seen.add(r);
        return http.Response(
            listing(
                contents: [object('media/a.mkv')],
                truncated: true,
                token: 't1'),
            200);
      })).list('/'),
      throwsA(isA<BackendUnreachable>()),
    );
    expect(seen, hasLength(2));
  });

  test('folders whose key holds // are reachable', () async {
    final heads = <http.Request>[];
    final b = backend(MockClient((r) async {
      if (r.method == 'HEAD') {
        heads.add(r);
        return http.Response('', 200, headers: {'content-length': '10'});
      }
      return switch (r.url.queryParameters['prefix']) {
        'media/a/' => http.Response(listing(prefixes: ['media/a//']), 200),
        'media/a//' =>
          http.Response(listing(contents: [object('media/a//x.mkv')]), 200),
        final p => http.Response('unexpected prefix $p', 500),
      };
    }));

    final dir = (await b.list('/a')).single;
    expect(dir.isDir, isTrue);
    expect(dir.path, '/a/');

    final file = (await b.list(dir.path)).single;
    expect(file.isDir, isFalse);
    expect(file.path, '/a//x.mkv');
    expect(file.name, 'x.mkv');

    final entry = await b.stat(file.path);
    expect(entry?.isDir, isFalse);
    expect(heads.single.url.path, '/bkt/media/a//x.mkv');

    final u = Uri.parse((await b.playable(file.path)).url);
    expect(u.path, '/bkt/media/a//x.mkv');
  });

  test('folders carry their key prefix as identity', () async {
    final b = backend(MockClient((r) async {
      if (r.method == 'HEAD') return http.Response('', 404);
      return switch (r.url.queryParameters['prefix']) {
        'media/' => http.Response(listing(prefixes: ['media/a/']), 200),
        'media/a/' => http.Response(listing(prefixes: ['media/a//']), 200),
        'media/a//' =>
          http.Response(listing(contents: [object('media/a//x.mkv')]), 200),
        final p => http.Response('unexpected prefix $p', 500),
      };
    }));

    expect((await b.stat('/'))?.identity, 'media/');
    expect((await b.list('/')).single.identity, 'media/a/');
    expect((await b.stat('/a'))?.identity, 'media/a/');
    final inner = (await b.list('/a')).single;
    expect(inner.identity, 'media/a//');
    expect((await b.stat(inner.path))?.identity, 'media/a//');
    // Files keep no identity: their path is where they are.
    expect((await b.list(inner.path)).single.identity, isNull);

    final bare = backend(
      MockClient((_) async => http.Response('', 500)),
      location: S3Location(
        endpoint: Uri.parse('https://h'),
        bucket: 'bkt',
        prefix: '',
        region: 'us-east-1',
        style: S3Style.path,
      ),
    );
    expect((await bare.stat('/'))?.identity, '/');
  });

  test('an empty first segment at the root is not listed', () async {
    final entries = await backend(MockClient((_) async => http.Response(
        listing(prefixes: ['media//', 'media/Movies/']), 200))).list('/');
    expect(entries.map((e) => e.path), ['/Movies']);
  });

  test('skips the folder marker', () async {
    final entries = await backend(MockClient((_) async => http.Response(
        listing(contents: [
          object('media/Movies/', size: 0),
          object('media/Movies/x.mkv'),
        ]),
        200))).list('/Movies');
    expect(entries.map((e) => e.path), ['/Movies/x.mkv']);
  });

  test('archived objects are unreadable', () async {
    final entries = await backend(MockClient((_) async => http.Response(
        listing(contents: [
          object('media/g.mkv', storageClass: 'GLACIER'),
          object('media/d.mkv', storageClass: 'DEEP_ARCHIVE'),
          object('media/s.mkv', storageClass: 'STANDARD'),
          object('media/i.mkv', storageClass: 'STANDARD_IA'),
          object('media/t.mkv', storageClass: 'INTELLIGENT_TIERING'),
        ]),
        200))).list('/');
    final unreadable = {for (final e in entries) e.name: e.unreadable};
    expect(unreadable, {
      'g.mkv': true,
      'd.mkv': true,
      's.mkv': false,
      'i.mkv': false,
      't.mkv': false,
    });
  });

  test('stat file', () async {
    late http.Request seen;
    final entry = await backend(MockClient((r) async {
      seen = r;
      return http.Response('', 200, headers: {
        'content-length': '1234',
        'last-modified': 'Fri, 02 Jan 2026 03:04:05 GMT',
      });
    })).stat('/Movies/x.mkv');

    expect(seen.method, 'HEAD');
    expect(seen.url.path, '/bkt/media/Movies/x.mkv');
    expect(entry, isNotNull);
    expect(entry!.isDir, isFalse);
    expect(entry.path, '/Movies/x.mkv');
    expect(entry.name, 'x.mkv');
    expect(entry.size, 1234);
    expect(entry.modified, DateTime.utc(2026, 1, 2, 3, 4, 5));
  });

  group('stat folder', () {
    test('a 404 with objects under the key is a dir', () async {
      final seen = <http.Request>[];
      final entry = await backend(MockClient((r) async {
        seen.add(r);
        if (r.method == 'HEAD') return http.Response('', 404);
        return http.Response(
            listing(contents: [object('media/Movies/x.mkv')]), 200);
      })).stat('/Movies');

      expect(seen, hasLength(2));
      expect(seen[1].method, 'GET');
      expect(seen[1].url.queryParameters['prefix'], 'media/Movies/');
      expect(seen[1].url.queryParameters['max-keys'], '1');
      expect(entry, isNotNull);
      expect(entry!.isDir, isTrue);
      expect(entry.path, '/Movies');
      expect(entry.name, 'Movies');
      expect(entry.size, 0);
    });

    test('a 404 with nothing under the key is null', () async {
      final entry = await backend(MockClient((r) async {
        if (r.method == 'HEAD') return http.Response('', 404);
        return http.Response(listing(), 200);
      })).stat('/Gone');
      expect(entry, isNull);
    });

    test('a HEAD 403 is PermissionLost', () async {
      await expectLater(
        backend(MockClient((_) async => http.Response('', 403)))
            .stat('/Movies/x.mkv'),
        throwsA(isA<BackendPermissionLost>()),
      );
    });
  });

  test('probe succeeds on an empty listing', () async {
    late http.Request seen;
    await backend(MockClient((r) async {
      seen = r;
      return http.Response(listing(), 200);
    })).probe();
    expect(seen.url.queryParameters['list-type'], '2');
    expect(seen.url.queryParameters['max-keys'], '1');
    expect(seen.url.queryParameters['prefix'], 'media/');
  });

  test('probe AccessDenied is CannotList', () async {
    const body = '<?xml version="1.0" encoding="UTF-8"?><Error>'
        '<Code>AccessDenied</Code><Message>Access Denied</Message></Error>';
    await expectLater(
      backend(MockClient((_) async => http.Response(body, 403))).probe(),
      throwsA(isA<BackendUnauthorized>()
          .having((e) => e.code, 'code', kS3CodeCannotList)),
    );
  });

  test('wrong region from header', () async {
    await expectLater(
      backend(MockClient((_) async => http.Response('', 301,
          headers: {'x-amz-bucket-region': 'eu-west-1'}))).probe(),
      throwsA(isA<BackendUnreachable>()
          .having((e) => e.code, 'code', kS3CodeWrongRegion)
          .having((e) => e.hint, 'hint', 'eu-west-1')),
    );
  });

  test('requests do not follow redirects', () async {
    late http.BaseRequest seen;
    await backend(MockClient((r) async {
      seen = r;
      return http.Response(listing(), 200);
    })).probe();
    expect(seen.followRedirects, isFalse);
  });

  group('path style and vhost style URLs', () {
    test('path', () {
      expect(_pathLocation.objectUri('media/a.mkv').toString(),
          'https://h:9000/bkt/media/a.mkv');
    });

    test('vhost', () {
      expect(_vhostLocation.objectUri('media/a.mkv').toString(),
          'https://bkt.s3.us-east-1.amazonaws.com/media/a.mkv');
    });

    test('the backend sends to the vhost host', () async {
      late http.Request seen;
      await backend(
        MockClient((r) async {
          seen = r;
          return http.Response('', 200, headers: {'content-length': '1'});
        }),
        location: _vhostLocation,
      ).stat('/a.mkv');
      expect(seen.url.host, 'bkt.s3.us-east-1.amazonaws.com');
      expect(seen.url.path, '/media/a.mkv');
    });
  });

  group('playable is a presigned URL with no headers', () {
    test('path', () async {
      final p = await backend(MockClient((_) async => http.Response('', 500)))
          .playable('/a.mkv');
      final u = Uri.parse(p.url);
      expect(p.headers, isEmpty);
      expect(u.host, 'h');
      expect(u.port, 9000);
      expect(u.path, '/bkt/media/a.mkv');
      expect(u.queryParameters['X-Amz-Expires'], '43200');
      expect(u.queryParameters['X-Amz-Signature'], isNotEmpty);
    });

    test('vhost', () async {
      final p = await backend(
        MockClient((_) async => http.Response('', 500)),
        location: _vhostLocation,
      ).playable('/a.mkv');
      final u = Uri.parse(p.url);
      expect(p.headers, isEmpty);
      expect(u.host, 'bkt.s3.us-east-1.amazonaws.com');
      expect(u.queryParameters['X-Amz-Expires'], '43200');
    });
  });

  test('keys round-trip from list to playable', () async {
    const key = 'media/Sp ace+&#%é /x.mkv';
    final heads = <http.Request>[];
    final b = backend(MockClient((r) async {
      if (r.method == 'HEAD') {
        heads.add(r);
        return http.Response('', 200, headers: {'content-length': '10'});
      }
      // S3 sends UTF-8; a String body would go out as Latin-1.
      return http.Response.bytes(
          utf8.encode(listing(contents: [object(xmlEscape(key))])), 200);
    }));

    final entries = await b.list('/Sp ace+&#%é ');
    expect(entries.single.path, '/Sp ace+&#%é /x.mkv');

    final entry = await b.stat(entries.single.path);
    expect(entry, isNotNull);
    final raw = heads.single.url.path;
    expect(raw, contains('%2B'));
    expect(raw, contains('%26'));
    expect(Uri.decodeComponent(raw), '/bkt/$key');

    final playable = await b.playable(entries.single.path);
    final u = Uri.parse(playable.url);
    expect(u.path, contains('%2B'));
    expect(u.path, contains('%26'));
    expect(Uri.decodeComponent(u.path), '/bkt/$key');
  });

  test('requests time out', () async {
    final never = Completer<http.Response>();
    await expectLater(
      backend(MockClient((_) => never.future),
              timeout: const Duration(milliseconds: 50))
          .probe(),
      throwsA(isA<BackendUnreachable>()),
    );
  });

  test('messages never carry the signature', () async {
    try {
      await backend(MockClient((_) async => throw http.ClientException(
              'boom', Uri.parse('https://h:9000/bkt?X-Amz-Signature=SECRET'))))
          .probe();
      fail('expected a failure');
    } on BackendFailure catch (e) {
      expect(e, isA<BackendUnreachable>());
      expect(e.toString(), isNot(contains('SECRET')));
    }
  });

  group('S3Location', () {
    test('connection URI round-trips', () {
      final u = _pathLocation.toConnectionUri();
      expect(u.toString(),
          's3+https://h:9000/bkt/media/?region=us-east-1&style=path');
      final back = S3Location.fromConnectionUri(u)!;
      expect(back.endpoint, Uri.parse('https://h:9000'));
      expect(back.bucket, 'bkt');
      expect(back.prefix, 'media/');
      expect(back.region, 'us-east-1');
      expect(back.style, S3Style.path);
    });

    test('a prefix without its trailing slash gains one; case is kept', () {
      final l = S3Location.fromConnectionUri(Uri.parse(
          's3+http://minio.lan/bkt/Media/TV?region=us-east-1&style=vhost'))!;
      expect(l.endpoint, Uri.parse('http://minio.lan'));
      expect(l.prefix, 'Media/TV/');
      expect(l.style, S3Style.vhost);
    });

    test('host is lowercased and the default port dropped', () {
      String canon(String u) => S3Location.fromConnectionUri(Uri.parse(u))!
          .toConnectionUri()
          .toString();
      expect(canon('S3+HTTPS://H.Example.com:443/bkt?style=path&region=r'),
          's3+https://h.example.com/bkt/?region=r&style=path');
      expect(canon('s3+http://H:80/bkt?region=r&style=path'),
          's3+http://h/bkt/?region=r&style=path');
      expect(canon('s3+http://h:443/bkt?region=r&style=path'),
          's3+http://h:443/bkt/?region=r&style=path');
      expect(canon('s3+https://[FE80::1]:9000/bkt?region=r&style=path'),
          's3+https://[fe80::1]:9000/bkt/?region=r&style=path');
    });

    test('an empty prefix stays empty', () {
      final l = S3Location.fromConnectionUri(
          Uri.parse('s3+https://h/bkt?region=r&style=path'))!;
      expect(l.prefix, '');
      expect(l.bucketUri({'list-type': '2'}).toString(),
          'https://h/bkt?list-type=2');
    });

    test('a non-S3 or incomplete URI is null', () {
      expect(S3Location.fromConnectionUri(Uri.parse('https://h/bkt')), isNull);
      expect(
          S3Location.fromConnectionUri(
              Uri.parse('s3+https://h/?region=r&style=path')),
          isNull);
      expect(
          S3Location.fromConnectionUri(
              Uri.parse('s3+https://h/bkt?style=path')),
          isNull);
      expect(
          S3Location.fromConnectionUri(
              Uri.parse('s3+https://h/bkt?region=r&style=other')),
          isNull);
    });

    test('bucketUri encodes query values', () {
      expect(
          _vhostLocation.bucketUri(
              {'prefix': 'media/a b+c', 'list-type': '2'}).toString(),
          'https://bkt.s3.us-east-1.amazonaws.com/'
          '?prefix=media%2Fa%20b%2Bc&list-type=2');
    });
  });
}
