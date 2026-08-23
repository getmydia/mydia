import 'dart:async';

import 'package:graphql_flutter/graphql_flutter.dart';

import '../player/device_profile.dart';

/// Callback function type for handling authentication errors.
/// Should attempt to refresh the token and return the new token if successful.
typedef OnAuthError = Future<String?> Function();

/// Callback resolved fresh on every request, mirroring how [AuthLink]'s
/// `getToken` is never baked into the client at construction time.
///
/// Returns null before the device probe has resolved (or on a platform with
/// nothing to probe and no static answer, which does not currently happen),
/// in which case [DeviceProfileLink] sends no header at all.
typedef GetDeviceProfile = FutureOr<DeviceProfile?> Function();

/// Attaches the current device profile to every request, read at request
/// time rather than fixed when the link is built.
///
/// `HttpLink.defaultHeaders` is baked in at construction, which is wrong for
/// a value that starts unknown and resolves only after the app is already
/// making requests: baking it in would mean either blocking client
/// construction on the probe (delaying the app's very first queries) or
/// rebuilding the client (and, with it, `GraphQLClient`'s link chain and the
/// subscriptions client's WebSocket) the moment the probe settles, which
/// orphans in-flight queries and forces a needless reconnect. Modeled on
/// [AuthLink]: [getDeviceProfile] runs once per outgoing request, so a
/// request that races ahead of the probe carries no header (the server's
/// documented no-profile behavior) and every request after the probe
/// resolves carries it, with the client built exactly once.
class DeviceProfileLink extends Link {
  DeviceProfileLink({required this.getDeviceProfile});

  final GetDeviceProfile getDeviceProfile;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    final profile = await getDeviceProfile();

    final outgoing = profile == null
        ? request
        : request.updateContextEntry<HttpLinkHeaders>(
            (headers) => HttpLinkHeaders(
              headers: {
                ...headers?.headers ?? const <String, String>{},
                DeviceProfile.headerName: profile.toHeaderValue(),
              },
            ),
          );

    yield* forward!(outgoing);
  }
}

/// Creates a GraphQL client configured for the Mydia backend.
///
/// [serverUrl] - Base URL of the Mydia server (e.g., "https://mydia.example.com")
/// [authToken] - Optional authentication token for the current user
/// [onAuthError] - Optional callback invoked when a 401 error occurs
/// [getDeviceProfile] - Optional per-request decode-capability lookup, see
/// [DeviceProfileLink]. Left unset, no request ever carries the header,
/// which is the same as the server's no-profile behavior.
GraphQLClient createGraphQLClient(
  String serverUrl,
  String? authToken, {
  OnAuthError? onAuthError,
  GetDeviceProfile? getDeviceProfile,
}) {
  // Ensure the server URL doesn't have a trailing slash
  final baseUrl = serverUrl.endsWith('/')
      ? serverUrl.substring(0, serverUrl.length - 1)
      : serverUrl;

  final httpLink = HttpLink('$baseUrl/api/graphql');

  final deviceProfileLink =
      DeviceProfileLink(getDeviceProfile: getDeviceProfile ?? () => null);

  // Add authentication header if token is provided
  final authLink = AuthLink(
    getToken: () async => authToken != null ? 'Bearer $authToken' : null,
  );

  // Add error handling for 401 responses
  final errorLink = ErrorLink(
    onGraphQLError: (request, forward, response) async* {
      final hasAuthError = response.errors?.any((error) {
            final message = error.message.toLowerCase();
            return message.contains('unauthorized') ||
                message.contains('unauthenticated') ||
                message.contains('401');
          }) ??
          false;

      if (hasAuthError && onAuthError != null) {
        final newToken = await onAuthError();
        if (newToken != null) {
          // Retry the request with new token by yielding forward
          // Note: The actual token update needs to happen in the provider layer
          yield* forward(request);
          return;
        }
      }

      yield response;
    },
    onException: (request, forward, exception) async* {
      // Handle HTTP-level errors
      if (exception is ServerException) {
        final parsedResponse = exception.parsedResponse;
        if (parsedResponse != null) {
          final statusCode = parsedResponse.response['statusCode'] as int?;
          if (statusCode == 401 && onAuthError != null) {
            final newToken = await onAuthError();
            if (newToken != null) {
              yield* forward(request);
              return;
            }
          }
        }
      }
      throw exception;
    },
  );

  final link =
      errorLink.concat(authLink.concat(deviceProfileLink.concat(httpLink)));

  return GraphQLClient(
    link: link,
    cache: GraphQLCache(store: HiveStore()),
  );
}

/// Creates a WebSocket link for GraphQL subscriptions.
///
/// [serverUrl] - Base URL of the Mydia server (e.g., "https://mydia.example.com")
/// [authToken] - Optional authentication token for the current user
WebSocketLink createWebSocketLink(String serverUrl, String? authToken) {
  // Convert http(s) to ws(s) for WebSocket connection
  final wsUrl = serverUrl
      .replaceFirst('http://', 'ws://')
      .replaceFirst('https://', 'wss://');

  final baseUrl =
      wsUrl.endsWith('/') ? wsUrl.substring(0, wsUrl.length - 1) : wsUrl;

  return WebSocketLink(
    '$baseUrl/api/graphql/socket',
    config: SocketClientConfig(
      autoReconnect: true,
      inactivityTimeout: const Duration(seconds: 30),
      initialPayload:
          authToken != null ? {'Authorization': 'Bearer $authToken'} : null,
    ),
  );
}

/// Creates a GraphQL client with both HTTP and WebSocket support.
///
/// This client can handle queries, mutations, and subscriptions.
/// [onAuthError] - Optional callback invoked when a 401 error occurs
/// [getDeviceProfile] - Optional per-request decode-capability lookup, see
/// [DeviceProfileLink] and [createGraphQLClient]. Only the HTTP leg carries
/// it; subscriptions run over the WebSocket link and never call into the
/// direct-play decision.
GraphQLClient createGraphQLClientWithSubscriptions(
  String serverUrl,
  String? authToken, {
  OnAuthError? onAuthError,
  GetDeviceProfile? getDeviceProfile,
}) {
  final baseUrl = serverUrl.endsWith('/')
      ? serverUrl.substring(0, serverUrl.length - 1)
      : serverUrl;

  final httpLink = HttpLink('$baseUrl/api/graphql');
  final deviceProfileLink =
      DeviceProfileLink(getDeviceProfile: getDeviceProfile ?? () => null);
  final wsLink = createWebSocketLink(serverUrl, authToken);

  final authLink = AuthLink(
    getToken: () async => authToken != null ? 'Bearer $authToken' : null,
  );

  // Add error handling for 401 responses
  final errorLink = ErrorLink(
    onGraphQLError: (request, forward, response) async* {
      final hasAuthError = response.errors?.any((error) {
            final message = error.message.toLowerCase();
            return message.contains('unauthorized') ||
                message.contains('unauthenticated') ||
                message.contains('401');
          }) ??
          false;

      if (hasAuthError && onAuthError != null) {
        final newToken = await onAuthError();
        if (newToken != null) {
          yield* forward(request);
          return;
        }
      }

      yield response;
    },
    onException: (request, forward, exception) async* {
      if (exception is ServerException) {
        final parsedResponse = exception.parsedResponse;
        if (parsedResponse != null) {
          final statusCode = parsedResponse.response['statusCode'] as int?;
          if (statusCode == 401 && onAuthError != null) {
            final newToken = await onAuthError();
            if (newToken != null) {
              yield* forward(request);
              return;
            }
          }
        }
      }
      throw exception;
    },
  );

  // Use HTTP for queries and mutations, WebSocket for subscriptions
  final link = Link.split(
    (request) => request.isSubscription,
    wsLink,
    errorLink.concat(authLink.concat(deviceProfileLink.concat(httpLink))),
  );

  return GraphQLClient(
    link: link,
    cache: GraphQLCache(store: HiveStore()),
  );
}
