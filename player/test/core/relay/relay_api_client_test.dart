import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/relay/pairing_key_handle.dart';
import 'package:player/core/relay/relay_api_client.dart';

/// A stand-in for the Rust-backed handle.
///
/// These tests cover the HTTP behaviour: which endpoint is called, what the URL
/// carries, the v1 fallback, and how failures map to exceptions. The derivation
/// and sealing are covered by Rust tests in `mydia_p2p_core` and
/// `mydia_player_p2p`, which is where that code lives.
///
/// Faking it is not merely convenient. CI's `Test / Player` job runs
/// `flutter test` with no cargo build, so a test that reaches `RustLib.init`
/// passes locally and fails in CI.
class _FakePairingKeys implements PairingKeyHandle {
  final String code;

  /// Blobs that "open"; anything else throws, standing in for a failed tag.
  static const _openable = 'VALID_SEALED_BLOB';

  _FakePairingKeys(this.code);

  /// Deterministic 64 hex chars, so assertions on shape and on the code never
  /// appearing in the URL stay meaningful.
  @override
  Future<String> lookupKey() async => code.codeUnits
      .map((u) => u.toRadixString(16).padLeft(2, '0'))
      .join()
      .padRight(64, '0')
      .substring(0, 64);

  @override
  Future<({String nodeAddr, String instanceId})> open(String sealed) async {
    if (sealed != _openable) {
      throw StateError('AEAD tag mismatch');
    }
    return (nodeAddr: 'addr', instanceId: 'inst');
  }
}

void main() {
  const relayUrl = 'https://relay.test';

  PairingKeyHandle fakeFactory(String code) => _FakePairingKeys(code);

  test('resolves a code through the v2 endpoint', () async {
    late Uri requested;

    final client = MockClient((request) async {
      requested = request.url;
      return http.Response(
        jsonEncode({'sealed': _FakePairingKeys._openable}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final api = RelayApiClient(
      baseUrl: relayUrl,
      client: client,
      pairingKeys: fakeFactory,
    );
    final result = await api.resolveClaimCode('K7RPM2');

    // The typed code must never appear in the URL: the relay sees only the
    // blinded lookup key. This is the property the whole change exists for.
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

    final api = RelayApiClient(
      baseUrl: relayUrl,
      client: client,
      pairingKeys: fakeFactory,
    );
    final result = await api.resolveClaimCode('K7RPM2');

    expect(paths.length, 2);
    expect(paths.last, '/pairing/claim/K7RPM2');
    expect(result.nodeAddr, '{"id":"abc"}');
    expect(result.instanceId, isNull);
  });

  test('throws InvalidClaimCodeException when both versions 404', () async {
    final client = MockClient((_) async => http.Response('{}', 404));
    final api = RelayApiClient(
      baseUrl: relayUrl,
      client: client,
      pairingKeys: fakeFactory,
    );

    expect(
      () => api.resolveClaimCode('K7RPM2'),
      throwsA(isA<InvalidClaimCodeException>()),
    );
  });

  test('throws RateLimitedException on 429', () async {
    final client = MockClient((_) async => http.Response('{}', 429));
    final api = RelayApiClient(
      baseUrl: relayUrl,
      client: client,
      pairingKeys: fakeFactory,
    );

    expect(
      () => api.resolveClaimCode('K7RPM2'),
      throwsA(isA<RateLimitedException>()),
    );
  });

  test('reports tampering distinctly when a blob fetches but will not open',
      () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({'sealed': 'a-blob-that-will-not-open'}),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    final api = RelayApiClient(
      baseUrl: relayUrl,
      client: client,
      pairingKeys: fakeFactory,
    );

    // Distinct from "invalid code": a wrong code cannot produce a lookup hit,
    // so a hit that will not open means the stored blob was altered.
    expect(
      () => api.resolveClaimCode('K7RPM2'),
      throwsA(isA<TamperedClaimException>()),
    );
  });
}
