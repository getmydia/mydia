import 'dart:convert';

import 'package:http/http.dart' as http;

import 'claim_resolve_result.dart';
import 'pairing_key_handle.dart';

export 'claim_resolve_result.dart'
    show ServerNotOnlineException, TamperedClaimException;

const _defaultRelayUrl = String.fromEnvironment(
  'RELAY_URL',
  defaultValue: 'https://relay.mydia.dev',
);

class RelayApiClient {
  final String baseUrl;
  final http.Client _client;
  final PairingKeyFactory _pairingKeys;

  RelayApiClient({
    this.baseUrl = _defaultRelayUrl,
    http.Client? client,
    PairingKeyFactory? pairingKeys,
  })  : _client = client ?? http.Client(),
        _pairingKeys = pairingKeys ?? defaultPairingKeyFactory;

  /// Resolves a claim code to the server's node address.
  ///
  /// Derives a blinded lookup key from the code and fetches a sealed blob, so
  /// the relay never sees the code or the address. Falls back to the v1
  /// endpoint when the relay has no v2 entry, which happens when the server has
  /// not been updated yet. Remove the fallback after one minor release.
  Future<ClaimResolveResult> resolveClaimCode(String code) async {
    final keys = _pairingKeys(code);
    final lookupKey = await keys.lookupKey();

    final response = await _get('$baseUrl/pairing/v2/claim/$lookupKey');

    if (response.statusCode == 404) {
      return _resolveViaV1(code);
    }

    _throwForStatus(response.statusCode);

    final sealed =
        (jsonDecode(response.body) as Map<String, dynamic>)['sealed'];
    if (sealed is! String || sealed.isEmpty) {
      throw Exception('Invalid response from relay: missing sealed blob');
    }

    final ({String nodeAddr, String instanceId}) payload;
    try {
      payload = await keys.open(sealed);
    } catch (_) {
      throw TamperedClaimException();
    }

    return ClaimResolveResult(
      nodeAddr: payload.nodeAddr,
      instanceId: payload.instanceId,
    );
  }

  Future<ClaimResolveResult> _resolveViaV1(String code) async {
    final response = await _get('$baseUrl/pairing/claim/$code');

    if (response.statusCode == 404) {
      throw InvalidClaimCodeException();
    }

    _throwForStatus(response.statusCode);

    return ClaimResolveResult.fromV1Json(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<http.Response> _get(String url) async {
    try {
      return await _client.get(Uri.parse(url));
    } on FormatException catch (e) {
      throw Exception('Invalid response from relay server: $e');
    } catch (e) {
      throw Exception('Network error connecting to relay: $e');
    }
  }

  void _throwForStatus(int status) {
    if (status == 429) {
      throw RateLimitedException();
    }

    if (status != 200) {
      throw Exception('Relay API error: $status');
    }
  }
}

class InvalidClaimCodeException implements Exception {
  @override
  String toString() => 'Invalid or expired claim code';
}

class RateLimitedException implements Exception {
  @override
  String toString() => 'Too many attempts. Please try again later.';
}
