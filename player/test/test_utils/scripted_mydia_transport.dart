import 'dart:async';

import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/mydia/mydia_gql_transport.dart';
import 'package:player/domain/sources/source_error.dart';

/// One request as the server saw it.
typedef ScriptedRequest = ({
  String operation,
  Map<String, dynamic> variables,
  String? token,
  Duration? timeout,
});

/// Answers a request. Return a data map, a [SourceException] or other
/// [Exception] to throw, or a [Future] of either to control timing.
typedef ScriptHandler = Object Function(ScriptedRequest request, int callIndex);

/// A [MydiaGqlTransport] scripted per request.
class ScriptedMydiaTransport implements MydiaGqlTransport {
  ScriptedMydiaTransport(this.handler);

  /// Answers in order, repeating the last answer once the list runs out.
  ScriptedMydiaTransport.responses(List<Object> responses)
      : handler = ((_, i) =>
            responses[i < responses.length ? i : responses.length - 1]);

  final ScriptHandler handler;
  final List<ScriptedRequest> requests = [];

  @override
  SourceConnectionStatus reachedVia = SourceConnectionStatus.remote;

  static String operationOf(String query) =>
      RegExp(r'(?:query|mutation)\s+(\w+)').firstMatch(query)?.group(1) ?? '';

  /// The requests for [operation], in order.
  List<ScriptedRequest> of(String operation) => [
        for (final r in requests)
          if (r.operation == operation) r
      ];

  @override
  Future<Map<String, dynamic>> send(
    String query,
    Map<String, dynamic> variables, {
    String? token,
    String? deviceProfile,
    Duration? timeout,
  }) async {
    final request = (
      operation: operationOf(query),
      variables: Map<String, dynamic>.of(variables),
      token: token,
      timeout: timeout,
    );
    final index = requests.length;
    requests.add(request);
    Object answer = handler(request, index);
    if (answer is Future) answer = await answer as Object;
    if (answer is Exception) throw answer;
    if (answer is Error) throw answer;
    return Map<String, dynamic>.from(answer as Map);
  }
}

/// A server-side GraphQL error, as `MydiaClient` surfaces one.
SourceException graphqlError(String message, {Map<String, dynamic>? data}) =>
    MydiaGraphqlError(message, data: data);
