import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/player/device_profile.dart';
import 'package:player/core/sources/mydia/mydia_gql_transport.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/domain/sources/source_error.dart';

void main() {
  test('attaches device profile header and authorization token when provided',
      () async {
    http.Request? captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'data': {'hello': 'world'}
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final transport = HttpMydiaTransport(
      serverUrl: 'https://mydia.test',
      http: SourceHttp(client: client),
    );

    final data = await transport.send(
      'query Test { hello }',
      {'var1': 'val1'},
      token: 'tok-123',
      deviceProfile: 'prof-abc',
    );

    expect(data, {'hello': 'world'});
    expect(captured, isNotNull);
    expect(captured!.headers['authorization'], 'Bearer tok-123');
    expect(
        captured!.headers[DeviceProfile.headerName.toLowerCase()], 'prof-abc');
  });

  test('omits device profile and auth headers when null', () async {
    http.Request? captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'data': {'status': 'ok'}
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final transport = HttpMydiaTransport(
      serverUrl: 'https://mydia.test',
      http: SourceHttp(client: client),
    );

    final data = await transport.send(
      'query Test { status }',
      {},
    );

    expect(data, {'status': 'ok'});
    expect(captured, isNotNull);
    expect(captured!.headers.containsKey('authorization'), isFalse);
    expect(
      captured!.headers.containsKey(DeviceProfile.headerName.toLowerCase()),
      isFalse,
    );
  });

  test('throws unauthorized on auth error response', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'errors': [
            {'message': 'Unauthorized'}
          ]
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final transport = HttpMydiaTransport(
      serverUrl: 'https://mydia.test',
      http: SourceHttp(client: client),
    );

    await expectLater(
      transport.send('query Test { a }', {}),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.unauthorized)),
    );
  });

  test('throws server on general GraphQL errors', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'errors': [
            {'message': 'Something went wrong'}
          ]
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final transport = HttpMydiaTransport(
      serverUrl: 'https://mydia.test',
      http: SourceHttp(client: client),
    );

    await expectLater(
      transport.send('query Test { a }', {}),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.server)
          .having((e) => e.message, 'message', 'Something went wrong')),
    );
  });
}
