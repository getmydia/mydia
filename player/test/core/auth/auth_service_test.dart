import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/auth/auth_storage.dart';

import '../../test_utils/mock_auth_storage.dart';
import 'auth_service_test.mocks.dart';

@GenerateMocks([http.Client])
void main() {
  group('AuthService', () {
    late MockAuthStorage mockStorage;
    late AuthServiceTestable service;

    setUp(() {
      mockStorage = MockAuthStorage();
      service = AuthServiceTestable(mockStorage);
    });

    group('token management', () {
      test('getToken returns null when not set', () async {
        final token = await service.getToken();
        expect(token, isNull);
      });

      test('setToken stores token', () async {
        await service.setToken('test-token');
        final token = await service.getToken();
        expect(token, equals('test-token'));
      });

      test('clearToken removes token', () async {
        await service.setToken('test-token');
        await service.clearToken();
        final token = await service.getToken();
        expect(token, isNull);
      });
    });

    group('server URL management', () {
      test('getServerUrl returns null when not set', () async {
        final url = await service.getServerUrl();
        expect(url, isNull);
      });

      test('setServerUrl stores URL', () async {
        await service.setServerUrl('https://example.com');
        final url = await service.getServerUrl();
        expect(url, equals('https://example.com'));
      });

      test('setServerUrl removes trailing slash', () async {
        await service.setServerUrl('https://example.com/');
        final url = await service.getServerUrl();
        expect(url, equals('https://example.com'));
      });

      test('setServerUrl removes multiple trailing slashes', () async {
        await service.setServerUrl('https://example.com///');
        // Only one trailing slash is removed per call
        final url = await service.getServerUrl();
        expect(url, equals('https://example.com//'));
      });

      test('clearServerUrl removes URL', () async {
        await service.setServerUrl('https://example.com');
        await service.clearServerUrl();
        final url = await service.getServerUrl();
        expect(url, isNull);
      });
    });

    group('user ID management', () {
      test('getUserId returns null when not set', () async {
        final userId = await service.getUserId();
        expect(userId, isNull);
      });

      test('setUserId stores user ID', () async {
        await service.setUserId('user-123');
        final userId = await service.getUserId();
        expect(userId, equals('user-123'));
      });
    });

    group('username management', () {
      test('getUsername returns null when not set', () async {
        final username = await service.getUsername();
        expect(username, isNull);
      });

      test('setUsername stores username', () async {
        await service.setUsername('testuser');
        final username = await service.getUsername();
        expect(username, equals('testuser'));
      });
    });

    group('relay URL management', () {
      test('getRelayUrl returns null when not set', () async {
        final relayUrl = await service.getRelayUrl();
        expect(relayUrl, isNull);
      });

      test('setRelayUrl stores relay URL', () async {
        await service.setRelayUrl('https://relay.example.com');
        final relayUrl = await service.getRelayUrl();
        expect(relayUrl, equals('https://relay.example.com'));
      });

      test('setRelayUrl removes trailing slash', () async {
        await service.setRelayUrl('https://relay.example.com/');
        final relayUrl = await service.getRelayUrl();
        expect(relayUrl, equals('https://relay.example.com'));
      });

      test('clearRelayUrl removes relay URL', () async {
        await service.setRelayUrl('https://relay.example.com');
        await service.clearRelayUrl();
        final relayUrl = await service.getRelayUrl();
        expect(relayUrl, isNull);
      });
    });

    group('session management', () {
      group('isAuthenticated', () {
        test('returns false when neither token nor URL are set', () async {
          final authenticated = await service.isAuthenticated();
          expect(authenticated, isFalse);
        });

        test('returns false when only token is set', () async {
          await service.setToken('test-token');
          final authenticated = await service.isAuthenticated();
          expect(authenticated, isFalse);
        });

        test('returns false when only URL is set', () async {
          await service.setServerUrl('https://example.com');
          final authenticated = await service.isAuthenticated();
          expect(authenticated, isFalse);
        });

        test('returns true when both token and URL are set', () async {
          await service.setToken('test-token');
          await service.setServerUrl('https://example.com');
          final authenticated = await service.isAuthenticated();
          expect(authenticated, isTrue);
        });
      });

      group('setSession', () {
        test('stores all session data', () async {
          await service.setSession(
            token: 'session-token',
            serverUrl: 'https://session.example.com',
            userId: 'user-456',
            username: 'sessionuser',
          );

          expect(await service.getToken(), equals('session-token'));
          expect(await service.getServerUrl(),
              equals('https://session.example.com'));
          expect(await service.getUserId(), equals('user-456'));
          expect(await service.getUsername(), equals('sessionuser'));
        });

        test('normalizes server URL', () async {
          await service.setSession(
            token: 'token',
            serverUrl: 'https://example.com/',
            userId: 'user',
            username: 'name',
          );

          expect(await service.getServerUrl(), equals('https://example.com'));
        });
      });

      group('clearSession', () {
        test('removes all session data', () async {
          await service.setSession(
            token: 'session-token',
            serverUrl: 'https://example.com',
            userId: 'user-456',
            username: 'sessionuser',
          );

          await service.clearSession();

          expect(await service.getToken(), isNull);
          expect(await service.getServerUrl(), isNull);
          expect(await service.getUserId(), isNull);
          expect(await service.getUsername(), isNull);
        });
      });

      group('getSession', () {
        test('returns empty session when not authenticated', () async {
          final session = await service.getSession();

          expect(session['token'], isNull);
          expect(session['serverUrl'], isNull);
          expect(session['userId'], isNull);
          expect(session['username'], isNull);
        });

        test('returns complete session when authenticated', () async {
          await service.setSession(
            token: 'test-token',
            serverUrl: 'https://example.com',
            userId: 'user-123',
            username: 'testuser',
          );

          final session = await service.getSession();

          expect(session['token'], equals('test-token'));
          expect(session['serverUrl'], equals('https://example.com'));
          expect(session['userId'], equals('user-123'));
          expect(session['username'], equals('testuser'));
        });
      });
    });

    group('verifyToken', () {
      late MockClient mockHttpClient;

      setUp(() {
        mockHttpClient = MockClient();
        service = AuthServiceTestable(mockStorage, httpClient: mockHttpClient);
      });

      test('returns false when token is not set', () async {
        await service.setServerUrl('https://example.com');
        final result = await service.verifyToken();
        expect(result, isFalse);
      });

      test('returns false when server URL is not set', () async {
        await service.setToken('test-token');
        final result = await service.verifyToken();
        expect(result, isFalse);
      });

      test('returns true on successful HTTP response', () async {
        await service.setToken('valid-token');
        await service.setServerUrl('https://example.com');

        when(mockHttpClient.post(
          Uri.parse('https://example.com/api/graphql'),
          headers: anyNamed('headers'),
          body: anyNamed('body'),
        )).thenAnswer((_) async => http.Response('{"data":{}}', 200));

        final result = await service.verifyToken();
        expect(result, isTrue);

        verify(mockHttpClient.post(
          Uri.parse('https://example.com/api/graphql'),
          headers: argThat(
            containsPair('Authorization', 'Bearer valid-token'),
            named: 'headers',
          ),
          body: argThat(
            equals(json.encode({'query': '{ __typename }'})),
            named: 'body',
          ),
        )).called(1);
      });

      test('returns false on 401 response', () async {
        await service.setToken('expired-token');
        await service.setServerUrl('https://example.com');

        when(mockHttpClient.post(
          Uri.parse('https://example.com/api/graphql'),
          headers: anyNamed('headers'),
          body: anyNamed('body'),
        )).thenAnswer((_) async => http.Response('Unauthorized', 401));

        final result = await service.verifyToken();
        expect(result, isFalse);
      });

      test('returns false on network exception', () async {
        await service.setToken('test-token');
        await service.setServerUrl('https://example.com');

        when(mockHttpClient.post(
          Uri.parse('https://example.com/api/graphql'),
          headers: anyNamed('headers'),
          body: anyNamed('body'),
        )).thenThrow(Exception('Network error'));

        final result = await service.verifyToken();
        expect(result, isFalse);
      });
    });
  });
}

/// Testable version of [AuthService] that allows dependency injection.
class AuthServiceTestable extends AuthService {
  final AuthStorage _testStorage;
  final http.Client? _testHttpClient;

  AuthServiceTestable(this._testStorage, {http.Client? httpClient})
      : _testHttpClient = httpClient;

  // Storage key constants from parent class
  static const _authTokenKey = 'auth_token';
  static const _serverUrlKey = 'server_url';
  static const _userIdKey = 'user_id';
  static const _usernameKey = 'username';
  static const _relayUrlKey = 'relay_url';

  @override
  Future<String?> getToken() async {
    return await _testStorage.read(_authTokenKey);
  }

  @override
  Future<void> setToken(String token) async {
    await _testStorage.write(_authTokenKey, token);
  }

  @override
  Future<void> clearToken() async {
    await _testStorage.delete(_authTokenKey);
  }

  @override
  Future<String?> getServerUrl() async {
    return await _testStorage.read(_serverUrlKey);
  }

  @override
  Future<void> setServerUrl(String url) async {
    final normalizedUrl =
        url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    await _testStorage.write(_serverUrlKey, normalizedUrl);
  }

  @override
  Future<void> clearServerUrl() async {
    await _testStorage.delete(_serverUrlKey);
  }

  @override
  Future<String?> getUserId() async {
    return await _testStorage.read(_userIdKey);
  }

  @override
  Future<void> setUserId(String userId) async {
    await _testStorage.write(_userIdKey, userId);
  }

  @override
  Future<String?> getUsername() async {
    return await _testStorage.read(_usernameKey);
  }

  @override
  Future<void> setUsername(String username) async {
    await _testStorage.write(_usernameKey, username);
  }

  @override
  Future<String?> getRelayUrl() async {
    return await _testStorage.read(_relayUrlKey);
  }

  @override
  Future<void> setRelayUrl(String url) async {
    final normalizedUrl =
        url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    await _testStorage.write(_relayUrlKey, normalizedUrl);
  }

  @override
  Future<void> clearRelayUrl() async {
    await _testStorage.delete(_relayUrlKey);
  }

  @override
  Future<bool> isAuthenticated() async {
    final token = await getToken();
    final serverUrl = await getServerUrl();
    return token != null && serverUrl != null;
  }

  @override
  Future<void> setSession({
    required String token,
    required String serverUrl,
    required String userId,
    required String username,
  }) async {
    await Future.wait([
      setToken(token),
      setServerUrl(serverUrl),
      setUserId(userId),
      setUsername(username),
    ]);
  }

  @override
  Future<void> clearSession() async {
    await Future.wait([
      clearToken(),
      clearServerUrl(),
      _testStorage.delete(_userIdKey),
      _testStorage.delete(_usernameKey),
    ]);
  }

  @override
  Future<Map<String, String?>> getSession() async {
    final results = await Future.wait([
      getToken(),
      getServerUrl(),
      getUserId(),
      getUsername(),
    ]);

    return {
      'token': results[0],
      'serverUrl': results[1],
      'userId': results[2],
      'username': results[3],
    };
  }

  @override
  Future<bool> verifyToken() async {
    final token = await getToken();
    final serverUrl = await getServerUrl();

    if (token == null || serverUrl == null) {
      return false;
    }

    try {
      final client = _testHttpClient ?? http.Client();
      final response = await client.post(
        Uri.parse('$serverUrl/api/graphql'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: json.encode({
          'query': '{ __typename }',
        }),
      );

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}
