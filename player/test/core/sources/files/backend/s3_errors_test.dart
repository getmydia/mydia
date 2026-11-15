import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/backend/s3_errors.dart';

String xml(String code, {String? region}) =>
    '<Error><Code>$code</Code><Message>m</Message>'
    '${region == null ? '' : '<Region>$region</Region>'}</Error>';

BackendFailure map(int status, String body,
        {bool atProbe = true, String? regionHeader}) =>
    s3Failure(
      status: status,
      body: body,
      host: 's3.example.com',
      bucket: 'mybucket',
      atProbe: atProbe,
      regionHeader: regionHeader,
    );

void noLeak(BackendFailure f) {
  expect(f.toString(), isNot(contains('X-Amz-Signature')));
  expect(f.toString(), isNot(contains('abc')));
  expect(f.toString(), isNot(contains('?')));
}

void main() {
  test('redactS3Url drops query and fragment', () {
    final r = redactS3Url(Uri.parse('https://h/b/k?X-Amz-Signature=abc#f'));
    expect(r, 'https://h/b/k');
    expect(r, isNot(contains('?')));
  });

  test('bad keys', () {
    for (final c in ['InvalidAccessKeyId', 'SignatureDoesNotMatch']) {
      final f = map(403, xml(c));
      expect(f, isA<BackendUnauthorized>());
      expect(f.code, kS3CodeBadKeys);
      noLeak(f);
    }
  });

  test('clock skew', () {
    final f = map(403, xml('RequestTimeTooSkewed'));
    expect(f, isA<BackendUnauthorized>());
    expect(f.code, kS3CodeClockSkew);
    noLeak(f);
  });

  test('AccessDenied at probe', () {
    final f = map(403, xml('AccessDenied'));
    expect(f, isA<BackendUnauthorized>());
    expect(f.code, kS3CodeCannotList);
  });

  test('AccessDenied after probe', () {
    final f = map(403, xml('AccessDenied'), atProbe: false);
    expect(f, isA<BackendPermissionLost>());
    noLeak(f);
  });

  test('NoSuchBucket', () {
    final f = map(404, xml('NoSuchBucket'));
    expect(f, isA<BackendNotFound>());
    expect(f.code, kS3CodeNoSuchBucket);
    expect(f.hint, 'mybucket');
  });

  test('wrong region from body', () {
    for (final r in [
      map(301, xml('PermanentRedirect', region: 'eu-west-1')),
      map(400, xml('AuthorizationHeaderMalformed', region: 'eu-west-1')),
    ]) {
      expect(r, isA<BackendUnreachable>());
      expect(r.code, kS3CodeWrongRegion);
      expect(r.hint, 'eu-west-1');
      noLeak(r);
    }
  });

  test('wrong region from header when body is empty', () {
    final f = map(301, '', regionHeader: 'eu-west-1');
    expect(f, isA<BackendUnreachable>());
    expect(f.code, kS3CodeWrongRegion);
    expect(f.hint, 'eu-west-1');
  });

  test('301 with no region anywhere', () {
    final f = map(301, '');
    expect(f.code, kS3CodeWrongRegion);
    expect(f.hint, isNull);
  });

  test('500 empty body', () {
    final f = map(500, '');
    expect(f, isA<BackendUnreachable>());
    expect((f as BackendUnreachable).status, 500);
    expect(f.code, isNull);
  });

  test('unparseable body gives null code', () {
    final f = map(500, '<<not xml');
    expect(f.code, isNull);
  });

  test('transport errors name the host', () {
    for (final e in [
      const SocketException('boom'),
      TimeoutException('t'),
      http.ClientException('c', Uri.parse('https://h/b?X-Amz-Signature=abc')),
    ]) {
      final f = s3TransportFailure(e, host: 's3.example.com');
      expect(f, isA<BackendUnreachable>());
      expect(f.message, contains('s3.example.com'));
      noLeak(f);
    }
  });

  test('handshake error is TLS', () {
    final f = s3TransportFailure(const HandshakeException('bad'),
        host: 's3.example.com');
    expect(f, isA<BackendUnreachable>());
    expect(f.code, kS3CodeTls);
  });
}
