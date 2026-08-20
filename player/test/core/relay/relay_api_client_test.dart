import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/relay/relay_api_client.dart';
import 'package:player/native/frb_generated.dart';

void main() {
  const relayUrl = 'https://relay.test';

  setUpAll(RustLib.init);

  test('resolves a code through the v2 endpoint', () async {
    late Uri requested;

    final client = MockClient((request) async {
      requested = request.url;
      return http.Response(
        jsonEncode({
          'sealed':
              'EUYQTYynGfrzBxQHoyyZIkDnbIotL7vvI-gUcW0Q_-nEAUWv9W9So494a2VK3NtbkGd2lmi1zOidl6us0Q',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final api = RelayApiClient(baseUrl: relayUrl, client: client);
    final result = await api.resolveClaimCode('K7RPM2');

    // The typed code must never appear in the URL.
    expect(requested.path, startsWith('/pairing/v2/claim/'));
    expect(requested.toString(), isNot(contains('K7RPM2')));
    expect(requested.pathSegments.last.length, 64);

    expect(result.nodeAddr, 'addr');
    expect(result.instanceId, 'inst');
  });

  test('falls back to v1 when v2 returns 404', () async {
    final paths = <String>[];

    final client = MockClient((request) async {
      paths.add(request.url.path);

      if (request.url.path.startsWith('/pairing/v2/')) {
        return http.Response('{}', 404);
      }

      return http.Response(
        jsonEncode({'node_addr': '{"id":"abc"}'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final api = RelayApiClient(baseUrl: relayUrl, client: client);
    final result = await api.resolveClaimCode('K7RPM2');

    expect(paths.length, 2);
    expect(paths.last, '/pairing/claim/K7RPM2');
    expect(result.nodeAddr, '{"id":"abc"}');
  });

  test('throws InvalidClaimCodeException when both versions 404', () async {
    final client = MockClient((_) async => http.Response('{}', 404));
    final api = RelayApiClient(baseUrl: relayUrl, client: client);

    expect(
      () => api.resolveClaimCode('K7RPM2'),
      throwsA(isA<InvalidClaimCodeException>()),
    );
  });

  test('throws RateLimitedException on 429', () async {
    final client = MockClient((_) async => http.Response('{}', 429));
    final api = RelayApiClient(baseUrl: relayUrl, client: client);

    expect(
      () => api.resolveClaimCode('K7RPM2'),
      throwsA(isA<RateLimitedException>()),
    );
  });

  test('reports tampering distinctly when a blob fetches but will not open',
      () async {
    final client = MockClient((_) async => http.Response(
          jsonEncode({'sealed': 'bm90LWEtcmVhbC1ibG9i'}),
          200,
          headers: {'content-type': 'application/json'},
        ));

    final api = RelayApiClient(baseUrl: relayUrl, client: client);

    expect(
      () => api.resolveClaimCode('K7RPM2'),
      throwsA(isA<TamperedClaimException>()),
    );
  });
}
