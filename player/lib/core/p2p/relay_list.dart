import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../auth/auth_storage.dart';
import '../relay/relay_api_client.dart' show metadataRelayBaseUrl;

/// The iroh relay compiled into this build, used when nothing else is
/// available. Overridable at build time with `--dart-define IROH_RELAY_URL`.
const String defaultIrohRelayUrl = 'https://cae1-1.relay.mydia.dev';

/// The build-time iroh relay override. Empty when not supplied.
const String buildTimeIrohRelayUrl = String.fromEnvironment('IROH_RELAY_URL');

/// Where the last successful fetch is cached.
///
/// AuthStorage rather than a file so the web build works unchanged: a browser
/// has no filesystem, and AuthStorage already abstracts that split.
///
/// Not to be confused with `_ConnectionStorageKeys.relayUrl` in
/// `core/connection/connection_provider.dart`, which records the relay a
/// paired server was reachable through. That key is a different thing and is
/// left alone.
const String relayListStorageKey = 'p2p_relays';

const Duration _timeout = Duration(seconds: 3);
const String _path = '/client-config';

/// Which precedence level produced a relay list.
enum RelayListSource { override, fetched, cached, defaultBuiltIn }

/// A resolved relay list and where it came from.
class RelayListResult {
  const RelayListResult(this.urls, this.source);

  final List<String> urls;
  final RelayListSource source;
}

/// Resolves which iroh relays this player should use.
///
/// Precedence, highest first: an explicit override (used alone, no request is
/// made), a successful fetch of the metadata relay's `/client-config`, the last
/// successful fetch from storage, then the compiled-in default.
///
/// iroh's own public relays are appended underneath whatever this returns, by
/// `build_relay_mode` in `native/mydia_p2p_core/src/lib.rs`.
///
/// `lib/mydia/p2p/relay_list.ex` is the Elixir twin of this function and
/// implements the same four levels and the same validation.
Future<RelayListResult> resolveRelayList({
  String? override,
  String baseUrl = metadataRelayBaseUrl,
  http.Client? client,
  AuthStorage? storage,
}) async {
  final effectiveOverride = _validUrls([
    if (override != null)
      override
    else if (buildTimeIrohRelayUrl.isNotEmpty)
      buildTimeIrohRelayUrl,
  ]);

  if (effectiveOverride.isNotEmpty) {
    return RelayListResult(effectiveOverride, RelayListSource.override);
  }

  final store = storage ?? getAuthStorage();
  final fetched = await _fetch(baseUrl, client);

  if (fetched.isNotEmpty) {
    await _writeCache(store, fetched);
    return RelayListResult(fetched, RelayListSource.fetched);
  }

  final cached = await _readCache(store);
  if (cached.isNotEmpty) {
    return RelayListResult(cached, RelayListSource.cached);
  }

  return const RelayListResult(
    [defaultIrohRelayUrl],
    RelayListSource.defaultBuiltIn,
  );
}

Future<List<String>> _fetch(String baseUrl, http.Client? client) async {
  final own = client == null;
  final httpClient = client ?? http.Client();

  try {
    final response = await httpClient.get(Uri.parse('$baseUrl$_path'),
        headers: {'accept': 'application/json'}).timeout(_timeout);

    if (response.statusCode != 200) {
      debugPrint(
          '[P2P] Relay list fetch returned ${response.statusCode}, falling back');
      return const [];
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return const [];

    // Unknown keys are ignored on purpose: the document is meant to grow
    // without a client change.
    final p2p = decoded['p2p'];
    if (p2p is! Map<String, dynamic>) return const [];

    final relays = p2p['relays'];
    if (relays is! List) return const [];

    return _validUrls(relays);
  } catch (e) {
    debugPrint('[P2P] Relay list fetch failed: $e, falling back');
    return const [];
  } finally {
    if (own) httpClient.close();
  }
}

List<String> _validUrls(List<dynamic> urls) {
  return urls
      .whereType<String>()
      .where((url) {
        final parsed = Uri.tryParse(url.trim());
        return parsed != null &&
            parsed.scheme == 'https' &&
            parsed.host.isNotEmpty;
      })
      .map((url) => url.trim())
      .toList();
}

Future<List<String>> _readCache(AuthStorage storage) async {
  try {
    final raw = await storage.read(relayListStorageKey);
    if (raw == null) return const [];

    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];

    return _validUrls(decoded);
  } catch (e) {
    debugPrint('[P2P] Could not read the cached relay list: $e');
    return const [];
  }
}

Future<void> _writeCache(AuthStorage storage, List<String> urls) async {
  try {
    await storage.write(relayListStorageKey, jsonEncode(urls));
  } catch (e) {
    // A cache we cannot write costs us the next offline start, nothing more.
    debugPrint('[P2P] Could not cache the relay list: $e');
  }
}
