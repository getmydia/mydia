import 'dart:async';

import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/mydia/mydia_gql_transport.dart';
import 'package:player/domain/sources/source_error.dart';

/// Answers by operation name, recording every call.
class FakeMydiaTransport implements MydiaGqlTransport {
  final Map<String,
          FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> vars)>
      handlers = {};
  final List<
      ({
        String operation,
        Map<String, dynamic> vars,
        String? token,
        String? deviceProfile,
      })> calls = [];

  /// Tokens the server accepts. Any other token answers unauthorized.
  Set<String> validTokens = {'access'};
  bool unreachable = false;

  static String operationOf(String query) =>
      RegExp(r'(?:query|mutation)\s+(\w+)').firstMatch(query)?.group(1) ?? '';

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
    final op = operationOf(query);
    calls.add((
      operation: op,
      vars: variables,
      token: token,
      deviceProfile: deviceProfile,
    ));
    if (unreachable) throw const SourceException.unreachable();
    if (op != 'RefreshAccessToken' && !validTokens.contains(token)) {
      throw const SourceException.unauthorized();
    }
    final handler = handlers[op];
    if (handler == null) throw SourceException.server('no handler for $op');
    return await handler(variables);
  }
}
