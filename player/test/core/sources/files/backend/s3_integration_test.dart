import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/backend/s3_backend.dart';
import 'package:player/core/sources/files/backend/s3_errors.dart';
import 'package:player/core/sources/files/backend/s3_signer.dart';

// Runs S3Backend against a real S3 server: RustFS, started locally by
// devenv's `mydia-s3` and in CI as a service container on `Test / Player`.
// Skipped when MYDIA_TEST_S3_ENDPOINT is unset, and locally when nothing
// listens there (devenv always sets it, `mydia-s3` may not be running). In CI
// an unreachable server fails instead, so a broken service container cannot
// pass as a skip.

const _region = 'us-east-1';
const _filmKey = 'lib/Films/Fictional Title (2020)/a.mkv';
const _oddDir = 'Sp ace+&#%é ';
const _oddKey = 'lib/Odd/$_oddDir/b.mkv';
const _markerKey = 'lib/Films/';
const _oddBody = 'odd key body';

final _env = Platform.environment;
final _endpoint = _env['MYDIA_TEST_S3_ENDPOINT'];

/// 64 KiB where byte i is i mod 251, so any range is checkable.
final _filmBytes = Uint8List.fromList(List.generate(65536, (i) => i % 251));

/// Why the group is skipped, or null to run it.
String? _skipReason() {
  final endpoint = _endpoint;
  if (endpoint == null || endpoint.isEmpty) {
    return 'MYDIA_TEST_S3_ENDPOINT is unset (start one with `mydia-s3`)';
  }
  if (_env.containsKey('CI')) return null;
  final uri = Uri.parse(endpoint);
  try {
    RawSynchronousSocket.connectSync(uri.host, uri.port).closeSync();
    return null;
  } on SocketException {
    return 'nothing listens at $endpoint (start it with `mydia-s3`)';
  }
}

void main() {
  final skip = _skipReason();
  group(
    'S3Backend against a real S3 server',
    skip: skip ?? false,
    () {
      final accessKey = _env['MYDIA_TEST_S3_ACCESS_KEY_ID'] ?? '';
      final secretKey = _env['MYDIA_TEST_S3_SECRET_ACCESS_KEY'] ?? '';
      final bucket = 'player-s3-${_randomSuffix()}';

      late S3Location location;
      late S3Signer signer;
      late http.Client client;
      late S3Backend backend;
      HttpOverrides? savedOverrides;
      final uploaded = <String>[];
      var bucketCreated = false;

      Future<http.Response> signed(
        String method,
        Uri uri, [
        List<int> body = const [],
      ]) async {
        final request = http.Request(method, uri)
          ..followRedirects = false
          ..bodyBytes = body
          ..headers.addAll(signer.sign(
            method: method,
            uri: uri,
            payloadSha256: sha256.convert(body).toString(),
          ));
        return http.Response.fromStream(await client.send(request));
      }

      Future<void> put(String key, List<int> body) async {
        final r = await signed('PUT', location.objectUri(key), body);
        expect(r.statusCode, 200, reason: 'PUT $key: ${r.body}');
        uploaded.add(key);
      }

      setUpAll(() async {
        // An earlier widget test in the CI bundle leaves a mock in
        // HttpOverrides.global that answers every request 400.
        savedOverrides = HttpOverrides.current;
        HttpOverrides.global = null;

        location = S3Location(
          endpoint: Uri.parse(_endpoint!),
          bucket: bucket,
          prefix: 'lib/',
          region: _region,
          style: S3Style.path,
        );
        signer = S3Signer(
          accessKeyId: accessKey,
          secretAccessKey: secretKey,
          region: _region,
        );
        client = http.Client();
        backend = S3Backend(
          location: location,
          accessKeyId: accessKey,
          secretAccessKey: secretKey,
          client: client,
        );

        final created = await signed('PUT', location.bucketUri());
        expect(created.statusCode, 200,
            reason: 'create bucket: ${created.body}');
        bucketCreated = true;

        await put(_filmKey, _filmBytes);
        await put(_oddKey, _oddBody.codeUnits);
        await put(_markerKey, const []);
      });

      tearDownAll(() async {
        try {
          for (final key in uploaded) {
            await signed('DELETE', location.objectUri(key));
          }
          if (bucketCreated) {
            final r = await signed('DELETE', location.bucketUri());
            expect(r.statusCode, 204, reason: 'delete bucket: ${r.body}');
          }
          client.close();
        } finally {
          HttpOverrides.global = savedOverrides;
        }
      });

      test('probe completes', () async {
        await backend.probe();
      });

      test('list of the root holds the two folders and no marker', () async {
        final entries = await backend.list('/');
        expect(
          entries.map((e) => (e.path, e.isDir)),
          unorderedEquals([('/Films', true), ('/Odd', true)]),
        );
      });

      test('stat of a file gives its size', () async {
        final entry = await backend.stat('/Films/Fictional Title (2020)/a.mkv');
        expect(entry, isNotNull);
        expect(entry!.isDir, isFalse);
        expect(entry.size, 65536);
      });

      test('stat of a folder gives a folder', () async {
        final entry = await backend.stat('/Films');
        expect(entry, isNotNull);
        expect(entry!.isDir, isTrue);
      });

      test('stat of a missing key gives null', () async {
        expect(await backend.stat('/nope.mkv'), isNull);
      });

      test('a presigned URL serves a byte range', () async {
        final playable =
            await backend.playable('/Films/Fictional Title (2020)/a.mkv');
        final r = await client.get(
          Uri.parse(playable.url),
          headers: {'Range': 'bytes=10-19'},
        );
        expect(r.statusCode, 206);
        expect(r.bodyBytes, _filmBytes.sublist(10, 20));
      });

      test('an odd key survives list, stat, playable and GET', () async {
        final odd = await backend.list('/Odd');
        expect(odd.map((e) => (e.path, e.isDir)), [('/Odd/$_oddDir', true)]);

        final inner = await backend.list(odd.single.path);
        final file = inner.single;
        expect(file.path, '/Odd/$_oddDir/b.mkv');
        expect(file.isDir, isFalse);

        final entry = await backend.stat(file.path);
        expect(entry?.size, _oddBody.length);

        final playable = await backend.playable(file.path);
        final r = await client.get(Uri.parse(playable.url));
        expect(r.statusCode, 200);
        expect(r.body, _oddBody);
      });

      test('a URL presigned 13 hours ago is refused', () async {
        final stale = S3Backend(
          location: location,
          accessKeyId: accessKey,
          secretAccessKey: secretKey,
          client: client,
          clock: () =>
              DateTime.now().toUtc().subtract(const Duration(hours: 13)),
        );
        final playable =
            await stale.playable('/Films/Fictional Title (2020)/a.mkv');
        final r = await client.get(Uri.parse(playable.url));
        expect(r.statusCode, 403);
      });

      test('a wrong secret fails the probe as bad keys', () async {
        final wrong = S3Backend(
          location: location,
          accessKeyId: accessKey,
          secretAccessKey: '$secretKey-wrong',
          client: client,
        );
        await expectLater(
          wrong.probe(),
          throwsA(isA<BackendUnauthorized>()
              .having((e) => e.code, 'code', kS3CodeBadKeys)),
        );
      });
    },
  );
}

String _randomSuffix() {
  final rng = Random.secure();
  return List.generate(8, (_) => rng.nextInt(36).toRadixString(36)).join();
}
