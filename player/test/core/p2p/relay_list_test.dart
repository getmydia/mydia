import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/auth/auth_storage.dart';
import 'package:player/core/p2p/relay_list.dart';

/// An in-memory AuthStorage so the resolver's cache can be asserted without a
/// platform channel.
class _MemoryStorage implements AuthStorage {
  final Map<String, String> values = {};

  @override
  bool get degraded => false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<void> deleteAll() async => values.clear();
}

const _fetched = 'https://relay-one.example.test';
const _other = 'https://relay-two.example.test';

http.Client _responds(int status, String body) =>
    MockClient((_) async => http.Response(body, status));

http.Client _fails() =>
    MockClient((_) async => throw http.ClientException('refused'));

http.Client _neverCalled() =>
    MockClient((_) async => fail('no request should have been made'));

void main() {
  group('override', () {
    test('wins outright and makes no request', () async {
      final result = await resolveRelayList(
        override: _other,
        client: _neverCalled(),
        storage: _MemoryStorage(),
      );

      expect(result.urls, [_other]);
      expect(result.source, RelayListSource.override);
    });

    test('a blank override is treated as unset', () async {
      final result = await resolveRelayList(
        override: '   ',
        client: _responds(
            200,
            jsonEncode({
              'p2p': {
                'relays': [_fetched]
              }
            })),
        storage: _MemoryStorage(),
      );

      expect(result.urls, [_fetched]);
      expect(result.source, RelayListSource.fetched);
    });

    test('a non-https override falls through', () async {
      final result = await resolveRelayList(
        override: 'ftp://nope.example.test',
        client: _responds(
            200,
            jsonEncode({
              'p2p': {
                'relays': [_fetched]
              }
            })),
        storage: _MemoryStorage(),
      );

      expect(result.source, RelayListSource.fetched);
    });
  });

  group('fetch', () {
    test('uses the fetched list and caches it', () async {
      final storage = _MemoryStorage();

      final result = await resolveRelayList(
        client: _responds(
            200,
            jsonEncode({
              'p2p': {
                'relays': [_fetched, _other]
              }
            })),
        storage: storage,
      );

      expect(result.urls, [_fetched, _other]);
      expect(result.source, RelayListSource.fetched);
      expect(
          jsonDecode(storage.values[relayListStorageKey]!), [_fetched, _other]);
    });

    test('drops entries that are not https URLs', () async {
      final result = await resolveRelayList(
        client: _responds(
            200,
            jsonEncode({
              'p2p': {
                'relays': ['http://insecure.test', 'not a url', _fetched]
              }
            })),
        storage: _MemoryStorage(),
      );

      expect(result.urls, [_fetched]);
    });

    test('ignores unknown keys', () async {
      final result = await resolveRelayList(
        client: _responds(
            200,
            jsonEncode({
              'future': {'thing': 1},
              'p2p': {
                'relays': [_fetched],
                'extra': 2
              }
            })),
        storage: _MemoryStorage(),
      );

      expect(result.urls, [_fetched]);
      expect(result.source, RelayListSource.fetched);
    });
  });

  group('fallback', () {
    Future<RelayListResult> withCache(http.Client client) {
      final storage = _MemoryStorage();
      storage.values[relayListStorageKey] = jsonEncode([_other]);
      return resolveRelayList(client: client, storage: storage);
    }

    test('a 500 falls back to the cache', () async {
      final result = await withCache(_responds(500, 'nope'));
      expect(result.urls, [_other]);
      expect(result.source, RelayListSource.cached);
    });

    test('a transport failure falls back to the cache', () async {
      final result = await withCache(_fails());
      expect(result.urls, [_other]);
      expect(result.source, RelayListSource.cached);
    });

    test('malformed JSON falls back to the cache', () async {
      final result = await withCache(_responds(200, '{{{'));
      expect(result.urls, [_other]);
      expect(result.source, RelayListSource.cached);
    });

    test('an empty list after filtering falls back to the cache', () async {
      final result = await withCache(_responds(
          200,
          jsonEncode({
            'p2p': {
              'relays': ['http://insecure.test']
            }
          })));
      expect(result.urls, [_other]);
      expect(result.source, RelayListSource.cached);
    });

    test('no cache falls back to the compiled-in default', () async {
      final result = await resolveRelayList(
        client: _responds(500, 'nope'),
        storage: _MemoryStorage(),
      );

      expect(result.urls, [defaultIrohRelayUrl]);
      expect(result.source, RelayListSource.defaultBuiltIn);
    });

    test('an unreadable cache falls back to the compiled-in default', () async {
      final storage = _MemoryStorage();
      storage.values[relayListStorageKey] = '{{{ not json';

      final result = await resolveRelayList(
        client: _responds(500, 'nope'),
        storage: storage,
      );

      expect(result.urls, [defaultIrohRelayUrl]);
      expect(result.source, RelayListSource.defaultBuiltIn);
    });

    test('a failed fetch does not overwrite a good cache', () async {
      final storage = _MemoryStorage();
      storage.values[relayListStorageKey] = jsonEncode([_other]);

      await resolveRelayList(client: _responds(500, 'nope'), storage: storage);

      expect(jsonDecode(storage.values[relayListStorageKey]!), [_other]);
    });
  });
}
