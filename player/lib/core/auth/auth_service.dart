import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:graphql/client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';

import 'auth_storage.dart';
import 'device_info_service.dart';
import '../graphql/client.dart';
import '../../graphql/mutations/login.graphql.dart';

/// Service for managing authentication tokens and server configuration.
///
/// Uses platform-appropriate secure storage to persist sensitive data
/// like auth tokens and server URLs. On native platforms, uses encrypted
/// storage. On web, uses localStorage.
class AuthService {
  /// [storage] is injectable for tests. Production callers use the default,
  /// which is the platform-appropriate implementation.
  AuthService({AuthStorage? storage}) : _storage = storage ?? getAuthStorage();

  final AuthStorage _storage;
  final DeviceInfoService _deviceInfo = DeviceInfoService();

  /// Whether durability can still be guaranteed for credential writes.
  ///
  /// True once at least one write has failed to reach secure storage. It does
  /// not mean every value is lost: writes before and after the failure may
  /// well have persisted. It means the app can no longer promise that what it
  /// just stored will be there next launch, which is enough to owe the user a
  /// warning instead of a success message.
  bool get storageDegraded => _storage.degraded;

  static const _authTokenKey = 'auth_token';
  static const _serverUrlKey = 'server_url';
  static const _userIdKey = 'user_id';
  static const _usernameKey = 'username';
  static const _relayUrlKey = 'relay_url';

  /// Get the stored authentication token.
  Future<String?> getToken() async {
    return await _storage.read(_authTokenKey);
  }

  /// Store an authentication token securely.
  Future<void> setToken(String token) async {
    await _storage.write(_authTokenKey, token);
  }

  /// Clear the stored authentication token.
  Future<void> clearToken() async {
    await _storage.delete(_authTokenKey);
  }

  /// Get the stored server URL.
  Future<String?> getServerUrl() async {
    return await _storage.read(_serverUrlKey);
  }

  /// Store the server URL.
  Future<void> setServerUrl(String url) async {
    // Ensure URL doesn't have trailing slash
    final normalizedUrl =
        url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    await _storage.write(_serverUrlKey, normalizedUrl);
  }

  /// Clear the stored server URL.
  Future<void> clearServerUrl() async {
    await _storage.delete(_serverUrlKey);
  }

  /// Get the stored user ID.
  Future<String?> getUserId() async {
    return await _storage.read(_userIdKey);
  }

  /// Store the user ID.
  Future<void> setUserId(String userId) async {
    await _storage.write(_userIdKey, userId);
  }

  /// Get the stored username.
  Future<String?> getUsername() async {
    return await _storage.read(_usernameKey);
  }

  /// Store the username.
  Future<void> setUsername(String username) async {
    await _storage.write(_usernameKey, username);
  }

  /// Get the stored custom relay URL.
  /// Returns null if no custom relay is configured (will use default).
  Future<String?> getRelayUrl() async {
    return await _storage.read(_relayUrlKey);
  }

  /// Store a custom relay URL.
  Future<void> setRelayUrl(String url) async {
    // Ensure URL doesn't have trailing slash
    final normalizedUrl =
        url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    await _storage.write(_relayUrlKey, normalizedUrl);
  }

  /// Clear the stored custom relay URL (revert to default).
  Future<void> clearRelayUrl() async {
    await _storage.delete(_relayUrlKey);
  }

  /// Check if user is authenticated (has both token and server URL).
  Future<bool> isAuthenticated() async {
    final token = await getToken();
    final serverUrl = await getServerUrl();
    return token != null && serverUrl != null;
  }

  /// Store complete session information.
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

  /// Clear all stored session data (logout).
  Future<void> clearSession() async {
    await Future.wait([
      clearToken(),
      clearServerUrl(),
      _storage.delete(_userIdKey),
      _storage.delete(_usernameKey),
    ]);
  }

  /// Get the complete session information.
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

  /// Login with username and password via GraphQL (recommended).
  ///
  /// Returns a map with session information on success, or throws an exception on failure.
  /// This method uses the GraphQL login mutation and includes device information.
  Future<Map<String, dynamic>> loginWithGraphQL({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final normalizedUrl = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;

    try {
      // Get device information
      final deviceId = await _deviceInfo.getDeviceId();
      final deviceName = await _deviceInfo.getDeviceName();
      final platform = _deviceInfo.getPlatform();

      // Create a temporary GraphQL client without authentication
      final client = createGraphQLClient(normalizedUrl, null);

      // Execute the login mutation
      final result = await client.mutate(
        MutationOptions(
          document: documentNodeMutationLogin,
          variables: Variables$Mutation$Login(
            username: username,
            password: password,
            deviceId: deviceId,
            deviceName: deviceName,
            platform: platform,
          ).toJson(),
        ),
      );

      // Check for errors
      if (result.hasException) {
        final errorMessage = result.exception?.graphqlErrors.isNotEmpty == true
            ? result.exception!.graphqlErrors.first.message
            : result.exception.toString();
        throw Exception('Login failed: $errorMessage');
      }

      final mutation =
          result.data != null ? Mutation$Login.fromJson(result.data!) : null;
      final loginData = mutation?.login;
      if (loginData == null) {
        throw Exception('No data returned from login mutation');
      }

      // Store the session
      await setSession(
        token: loginData.token,
        serverUrl: normalizedUrl,
        userId: loginData.user.id,
        username: loginData.user.username ?? username,
      );

      return {
        'token': loginData.token,
        'serverUrl': normalizedUrl,
        'userId': loginData.user.id,
        'username': loginData.user.username ?? username,
        'email': loginData.user.email,
        'displayName': loginData.user.displayName,
        'expiresIn': loginData.expiresIn,
      };
    } catch (e) {
      throw Exception('Login error: $e');
    }
  }

  /// Login with username and password via the REST API (legacy).
  ///
  /// Returns a map with session information on success, or throws an exception on failure.
  /// The backend uses Guardian JWT tokens, which are returned in the response.
  ///
  /// NOTE: This method is deprecated. Use [loginWithGraphQL] instead.
  @Deprecated('Use loginWithGraphQL instead')
  Future<Map<String, dynamic>> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final normalizedUrl = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;

    final loginUrl = Uri.parse('$normalizedUrl/auth/local/login');

    try {
      final response = await http.post(
        loginUrl,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: {
          'user[username]': username,
          'user[password]': password,
        },
      );

      if (response.statusCode == 302 || response.statusCode == 200) {
        // Parse the Set-Cookie header to extract the guardian token
        final cookies = response.headers['set-cookie'];
        if (cookies == null) {
          throw Exception('No session cookie received from server');
        }

        // Extract guardian_token from cookies
        // Cookie format: _mydia_key=...; guardian_token=TOKEN; ...
        final guardianTokenMatch =
            RegExp(r'guardian_token=([^;]+)').firstMatch(cookies);
        if (guardianTokenMatch == null) {
          throw Exception('No guardian token found in response');
        }

        final token = guardianTokenMatch.group(1)!;

        // Store the session
        await setSession(
          token: token,
          serverUrl: normalizedUrl,
          userId: '', // Will be populated from user info endpoint if needed
          username: username,
        );

        return {
          'token': token,
          'serverUrl': normalizedUrl,
          'username': username,
        };
      } else {
        final errorBody = response.body;
        throw Exception(
            'Login failed with status ${response.statusCode}: $errorBody');
      }
    } catch (e) {
      throw Exception('Login error: $e');
    }
  }

  /// Storage key for the durable device token handed out during pairing.
  ///
  /// Written by `PairingService`; survives access token expiry, which is what
  /// makes unattended refresh possible.
  static const _deviceTokenKey = 'pairing_device_token';

  /// Mutation that trades the pairing device token for a fresh access token.
  ///
  /// Deliberately unauthenticated on the server: the device token is the proof
  /// of identity. Written as a raw document so it works over both the HTTP
  /// client and the P2P link without depending on codegen output.
  static const refreshAccessTokenMutation = r'''
mutation RefreshAccessToken($deviceToken: String!) {
  refreshAccessToken(deviceToken: $deviceToken) {
    token
    expiresAt
  }
}
''';

  /// Get the durable pairing device token, if this client was paired.
  Future<String?> getDeviceToken() async {
    return await _storage.read(_deviceTokenKey);
  }

  /// Refresh the access token over HTTP (direct connection mode).
  ///
  /// Access tokens expire well before a pairing does, so without this a paired
  /// client silently drops to unauthenticated and every gated request fails.
  /// Returns the new token, or null when the client cannot re-authenticate on
  /// its own and the user has to pair again.
  Future<String?> refreshToken() async {
    final deviceToken = await getDeviceToken();
    final serverUrl = await getServerUrl();

    if (deviceToken == null || serverUrl == null) return null;

    try {
      // No auth on this client: the mutation is intentionally public.
      final client = createGraphQLClient(serverUrl, null);

      final result = await client.mutate(
        MutationOptions(
          document: gql(refreshAccessTokenMutation),
          variables: {'deviceToken': deviceToken},
          fetchPolicy: FetchPolicy.noCache,
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[AuthService] Access token refresh failed: ${result.exception}');
        return null;
      }

      return await _storeRefreshedToken(result.data);
    } catch (e) {
      debugPrint('[AuthService] Access token refresh error: $e');
      return null;
    }
  }

  /// Refresh the access token over an arbitrary transport.
  ///
  /// The P2P link owns its own transport, so it supplies [send] rather than
  /// having this service reach into the P2P stack. [send] receives the mutation
  /// document and variables and returns the decoded `data` map.
  Future<String?> refreshTokenVia(
    Future<Map<String, dynamic>> Function(
      String query,
      Map<String, dynamic> variables,
    ) send,
  ) async {
    final deviceToken = await getDeviceToken();
    if (deviceToken == null) return null;

    try {
      final data = await send(
        refreshAccessTokenMutation,
        {'deviceToken': deviceToken},
      );
      return await _storeRefreshedToken(data);
    } catch (e) {
      debugPrint('[AuthService] Access token refresh error: $e');
      return null;
    }
  }

  /// Persist a refreshed access token so later requests pick it up.
  Future<String?> _storeRefreshedToken(Map<String, dynamic>? data) async {
    final payload = data?['refreshAccessToken'];
    if (payload is! Map) return null;

    final token = payload['token'];
    if (token is! String || token.isEmpty) return null;

    await setToken(token);
    debugPrint('[AuthService] Access token refreshed');
    return token;
  }

  /// Verify the current token is still valid by making a test API call.
  Future<bool> verifyToken() async {
    final token = await getToken();
    final serverUrl = await getServerUrl();

    if (token == null || serverUrl == null) {
      return false;
    }

    try {
      // Make a simple GraphQL query to test the token
      final response = await http.post(
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

/// Provider for the auth service.
final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService();
});
