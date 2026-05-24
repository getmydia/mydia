import 'package:graphql_flutter/graphql_flutter.dart';

/// Callback function type for handling authentication errors.
/// Should attempt to refresh the token and return the new token if successful.
typedef OnAuthError = Future<String?> Function();

/// Creates a GraphQL client configured for the Mydia backend.
///
/// [serverUrl] - Base URL of the Mydia server (e.g., "https://mydia.example.com")
/// [authToken] - Optional authentication token for the current user
/// [onAuthError] - Optional callback invoked when a 401 error occurs
GraphQLClient createGraphQLClient(
  String serverUrl,
  String? authToken, {
  OnAuthError? onAuthError,
}) {
  // Ensure the server URL doesn't have a trailing slash
  final baseUrl = serverUrl.endsWith('/')
      ? serverUrl.substring(0, serverUrl.length - 1)
      : serverUrl;

  final httpLink = HttpLink('$baseUrl/api/graphql');

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

  final link = errorLink.concat(authLink.concat(httpLink));

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
GraphQLClient createGraphQLClientWithSubscriptions(
  String serverUrl,
  String? authToken, {
  OnAuthError? onAuthError,
}) {
  final baseUrl = serverUrl.endsWith('/')
      ? serverUrl.substring(0, serverUrl.length - 1)
      : serverUrl;

  final httpLink = HttpLink('$baseUrl/api/graphql');
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
    errorLink.concat(authLink.concat(httpLink)),
  );

  return GraphQLClient(
    link: link,
    cache: GraphQLCache(store: HiveStore()),
  );
}
