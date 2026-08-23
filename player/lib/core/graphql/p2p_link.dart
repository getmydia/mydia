import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show AnyhowException;
import 'package:gql/language.dart' show printNode;
import 'package:graphql_flutter/graphql_flutter.dart';

import '../p2p/p2p_service.dart';
import '../player/device_profile.dart';

/// Max number of retry attempts for transient connection errors.
const _maxRetries = 3;

/// Base backoff duration (doubles each retry: 1s, 2s, 4s).
const _baseBackoff = Duration(seconds: 1);

/// A GraphQL Link that sends operations over P2P.
///
/// This link is used when the app is connected via P2P mode instead of
/// direct HTTP connections. It routes GraphQL queries and mutations through
/// the P2P layer to the Mydia server.
///
/// Includes automatic retry with exponential backoff for transient connection
/// errors. Between retries, it calls [ensureConnected] to re-dial the peer.
/// Server error text returned when a request carries no valid access token.
///
/// Access tokens outlive nothing in particular: they expire on the server's
/// Guardian TTL while the pairing itself stays valid, so this is an expected
/// condition to recover from rather than a fatal one.
const _authErrorMarker = 'Authentication required';

class P2pGraphQLLink extends Link {
  final P2pService _p2pService;
  final String _serverNodeId;
  final Future<String?> Function() _getAuthToken;
  final Future<String?> Function()? _refreshAuthToken;

  P2pGraphQLLink({
    required P2pService p2pService,
    required String serverNodeId,
    required Future<String?> Function() getAuthToken,
    Future<String?> Function()? refreshAuthToken,
  })  : _p2pService = p2pService,
        _serverNodeId = serverNodeId,
        _getAuthToken = getAuthToken,
        _refreshAuthToken = refreshAuthToken;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    try {
      // Get the current auth token
      final authToken = await _getAuthToken();

      // Convert the request document to a query string using gql's built-in printer
      final query = printNode(request.operation.document);
      final operationName = request.operation.operationName;
      final variables = request.variables;

      debugPrint('[P2pGraphQLLink] Sending request: $operationName');

      // Read fresh on every request, same as `DeviceProfileLink` does for the
      // HTTP path (see `client.dart`): a request issued before the probe
      // resolves carries null, which degrades to the server's no-profile
      // behavior, and one issued after picks up the profile with nothing
      // else to rebuild.
      final deviceProfile =
          DeviceProfileHolder.instance.profile?.toHeaderValue();

      // Attempt the request with retries on connection errors
      final responseData = await _sendWithAuthRecovery(
        query: query,
        operationName: operationName,
        variables: variables.isNotEmpty ? variables : null,
        authToken: authToken,
        deviceProfile: deviceProfile,
      );

      debugPrint('[P2pGraphQLLink] Received response');

      // Create the response
      yield Response(
        data: responseData,
        context: request.context,
        response: const {},
      );
    } catch (e, stackTrace) {
      debugPrint('[P2pGraphQLLink] Error: $e');
      debugPrint('[P2pGraphQLLink] Stack: $stackTrace');

      // Yield an error response
      yield Response(
        errors: [
          GraphQLError(
            message: e.toString(),
          ),
        ],
        context: request.context,
        response: const {},
      );
    }
  }

  /// Send a request, refreshing the access token once if the server rejects it.
  ///
  /// A paired client keeps a durable device token, so an expired access token is
  /// recoverable without user involvement. Without this the client would stay
  /// permanently unauthenticated until someone re-paired it by hand.
  Future<Map<String, dynamic>> _sendWithAuthRecovery({
    required String query,
    String? operationName,
    Map<String, dynamic>? variables,
    String? authToken,
    String? deviceProfile,
  }) async {
    try {
      return await _sendWithRetry(
        query: query,
        operationName: operationName,
        variables: variables,
        authToken: authToken,
        deviceProfile: deviceProfile,
      );
    } catch (e) {
      final refresh = _refreshAuthToken;
      if (refresh == null || !_isAuthError(e)) rethrow;

      debugPrint('[P2pGraphQLLink] Access token rejected, refreshing');
      final refreshed = await refresh();

      if (refreshed == null) {
        debugPrint('[P2pGraphQLLink] Refresh failed, device must pair again');
        rethrow;
      }

      return await _sendWithRetry(
        query: query,
        operationName: operationName,
        variables: variables,
        authToken: refreshed,
        deviceProfile: deviceProfile,
      );
    }
  }

  /// Whether the server rejected the request for lack of a valid token.
  ///
  /// Matches on the message because the P2P transport surfaces GraphQL errors as
  /// plain [Exception]s with no structured error code to key off.
  static bool _isAuthError(Object error) =>
      error.toString().contains(_authErrorMarker);

  /// Send a GraphQL request with automatic retry on connection errors.
  ///
  /// Retries up to [_maxRetries] times with exponential backoff.
  /// Between retries, calls [ensureConnected] to re-dial the peer.
  Future<Map<String, dynamic>> _sendWithRetry({
    required String query,
    String? operationName,
    Map<String, dynamic>? variables,
    String? authToken,
    String? deviceProfile,
  }) async {
    Object? lastError;
    StackTrace? lastStack;

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        return await _p2pService.sendGraphQLRequest(
          peer: _serverNodeId,
          query: query,
          variables: variables,
          operationName: operationName,
          authToken: authToken,
          deviceProfile: deviceProfile,
        );
      } catch (e, stackTrace) {
        lastError = e;
        lastStack = stackTrace;

        // Don't retry on the last attempt
        if (attempt >= _maxRetries) break;

        // Only retry on connection/timeout errors, not GraphQL business errors
        if (!_isRetryableError(e)) {
          debugPrint(
              '[P2pGraphQLLink] Non-retryable error, failing immediately: $e');
          rethrow;
        }

        final backoff = _baseBackoff * (1 << attempt); // 1s, 2s, 4s
        debugPrint(
          '[P2pGraphQLLink] Attempt ${attempt + 1} failed, '
          'retrying in ${backoff.inSeconds}s: $e',
        );

        await Future.delayed(backoff);

        // Try to re-establish the connection before retrying
        try {
          await _p2pService.ensureConnected(_serverNodeId);
        } catch (reconnectError) {
          debugPrint(
              '[P2pGraphQLLink] Reconnect attempt failed: $reconnectError');
        }
      }
    }

    // All retries exhausted
    debugPrint('[P2pGraphQLLink] All $_maxRetries retries exhausted');
    debugPrint('[P2pGraphQLLink] Last stack: $lastStack');
    throw lastError!;
  }

  /// Returns true if the error is a transient connection/timeout error
  /// that is worth retrying.
  ///
  /// [AnyhowException] comes from the Rust FFI layer (flutter_rust_bridge)
  /// and indicates a P2P transport-level failure (timeout, connection drop,
  /// peer unreachable, etc). These are always worth retrying.
  ///
  /// [TimeoutException] is a Dart-level timeout, also retryable.
  ///
  /// Regular [Exception]s thrown from [P2pService.sendGraphQLRequest] are
  /// GraphQL business errors (parsed from the response) and should NOT
  /// be retried.
  static bool _isRetryableError(Object error) {
    return error is AnyhowException || error is TimeoutException;
  }
}

/// Creates a GraphQL client configured for P2P mode.
///
/// [p2pService] - The P2P service instance for sending requests
/// [serverNodeId] - The node ID of the Mydia server to connect to
/// [getAuthToken] - A function that returns the current auth token
/// [refreshAuthToken] - Mints a fresh access token when the server rejects the
/// current one, returning null if the device has to pair again
GraphQLClient createP2pGraphQLClient({
  required P2pService p2pService,
  required String serverNodeId,
  required Future<String?> Function() getAuthToken,
  Future<String?> Function()? refreshAuthToken,
}) {
  final link = P2pGraphQLLink(
    p2pService: p2pService,
    serverNodeId: serverNodeId,
    getAuthToken: getAuthToken,
    refreshAuthToken: refreshAuthToken,
  );

  return GraphQLClient(
    link: link,
    cache: GraphQLCache(store: HiveStore()),
  );
}
