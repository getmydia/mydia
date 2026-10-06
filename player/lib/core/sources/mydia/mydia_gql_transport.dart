/// How a Mydia server's GraphQL travels: HTTP to its URL, or p2p to its node.
library;

import '../../../domain/sources/source_error.dart';
import '../../p2p/p2p_service.dart';
import '../../player/device_profile.dart';
import '../media_source.dart';
import '../source_http.dart';

/// The server answered with GraphQL errors. [data] is whatever it still
/// resolved, when it sent any.
class MydiaGraphqlError extends SourceException {
  const MydiaGraphqlError(String message, {this.data})
      : super(SourceErrorKind.server, message);

  final Map<String, dynamic>? data;
}

abstract interface class MydiaGqlTransport {
  /// The response's `data`. Throws [SourceException]: `unauthorized` when
  /// the server refused the token, `unreachable` when it could not be
  /// reached, [MydiaGraphqlError] for any other GraphQL error.
  ///
  /// [timeout] bounds one request over HTTP and defaults to
  /// [SourceHttp.defaultTimeout]. A p2p transport ignores it: its request
  /// deadline is the server's own, not the client's.
  Future<Map<String, dynamic>> send(
    String query,
    Map<String, dynamic> variables, {
    String? token,
    String? deviceProfile,
    Duration? timeout,
  });

  /// The status a successful request reports.
  SourceConnectionStatus get reachedVia;
}

/// Absinthe's and the p2p server's wording for a missing or bad token.
bool isMydiaAuthError(String message) {
  final lower = message.toLowerCase();
  return lower.contains('unauthorized') ||
      lower.contains('unauthenticated') ||
      lower.contains('authentication required');
}

class HttpMydiaTransport implements MydiaGqlTransport {
  HttpMydiaTransport({required String serverUrl, required SourceHttp http})
      : _url = Uri.parse('$serverUrl/api/graphql'),
        _http = http;

  final Uri _url;
  final SourceHttp _http;

  @override
  SourceConnectionStatus get reachedVia => SourceConnectionStatus.remote;

  @override
  Future<Map<String, dynamic>> send(
    String query,
    Map<String, dynamic> variables, {
    String? token,
    String? deviceProfile,
    Duration? timeout,
  }) async {
    final body = await _http.json(
      'POST',
      _url,
      timeout: timeout ?? SourceHttp.defaultTimeout,
      headers: {
        if (token != null) 'Authorization': 'Bearer $token',
        if (deviceProfile != null) DeviceProfile.headerName: deviceProfile,
      },
      body: {'query': query, 'variables': variables},
    );
    if (body is! Map<String, dynamic>) {
      throw const SourceException.server(
          'The server sent a response this app cannot read.');
    }
    final errors = body['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      final message =
          first is Map ? (first['message'] as String? ?? '') : '$first';
      if (isMydiaAuthError(message)) throw const SourceException.unauthorized();
      final partial = body['data'];
      throw MydiaGraphqlError(message,
          data: partial is Map<String, dynamic> ? partial : null);
    }
    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw const SourceException.server('The server sent no data.');
    }
    return data;
  }
}

class P2pMydiaTransport implements MydiaGqlTransport {
  P2pMydiaTransport({required P2pService p2p, required String nodeAddr})
      : _p2p = p2p,
        _nodeAddr = nodeAddr;

  final P2pService _p2p;
  final String _nodeAddr;

  @override
  SourceConnectionStatus get reachedVia => SourceConnectionStatus.remote;

  @override
  Future<Map<String, dynamic>> send(
    String query,
    Map<String, dynamic> variables, {
    String? token,
    String? deviceProfile,
    Duration? timeout,
  }) async {
    try {
      return await _p2p.sendGraphQLRequest(
        peer: _nodeAddr,
        query: query,
        variables: variables,
        authToken: token,
        deviceProfile: deviceProfile,
      );
    } on P2pGraphQLError catch (e) {
      if (isMydiaAuthError(e.message)) {
        throw const SourceException.unauthorized();
      }
      // `P2pGraphQLError` carries no partial data, so none is attached.
      throw MydiaGraphqlError(e.message);
    } catch (_) {
      // Dial, connect and timeout failures never come from the server's
      // answer, so they all mean it could not be reached.
      throw const SourceException.unreachable();
    }
  }
}
