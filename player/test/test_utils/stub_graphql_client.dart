import 'package:graphql_flutter/graphql_flutter.dart';

/// Returns the response for the [callIndex]-th request, or an [Exception] to
/// throw, or a fully built [Response]. May also return a [Future] of any of
/// those, so a test can hold one query's answer back to control its timing
/// relative to another.
typedef StubHandler = Object Function(Request request, int callIndex);

/// A [Link] that answers from a script instead of a server.
///
/// Every response `data` map must carry `__typename` on each object,
/// including the response root itself (e.g. `'__typename': 'Query'`
/// alongside the top-level fields): `gql()` injects a `__typename` selection
/// into every selection set in the outgoing document, root included, and the
/// normalized cache refuses to write data that lacks a matching one (which
/// surfaces as a spurious `result.hasException`, not as an obvious error).
class StubLink extends Link {
  StubLink(this.handler);

  /// Answers each call from [responses] in order, repeating the last entry
  /// once the script runs out.
  StubLink.responses(List<Object> responses)
      : assert(
          responses.isNotEmpty,
          'StubLink.responses requires at least one response',
        ),
        handler = ((_, index) =>
            responses[index < responses.length ? index : responses.length - 1]);

  final StubHandler handler;

  /// Every request this link has seen, in order.
  final List<Request> requests = [];

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    final index = requests.length;
    requests.add(request);

    final raw = handler(request, index);
    // A handler may hold a response back (a Completer's future) so a test
    // can control when one query lands relative to another.
    final outcome = raw is Future ? await raw : raw;
    if (outcome is Exception) throw outcome;
    if (outcome is Response) {
      yield outcome;
      return;
    }
    yield Response(
      data: outcome as Map<String, dynamic>,
      response: const <String, dynamic>{},
    );
  }
}

/// A real [GraphQLClient] over a scripted link and a non-persistent cache.
GraphQLClient stubClient(Link link, {GraphQLCache? cache}) => GraphQLClient(
      link: link,
      cache: cache ?? GraphQLCache(store: InMemoryStore()),
      queryRequestTimeout: null,
    );

/// Whether [request] carries the GraphQL operation named [name].
///
/// `request.operation.operationName` is null for everything the player
/// issues, because `QueryOptions`/`MutationOptions` never set it, and
/// graphql_flutter does not re-export the `gql` AST node types a document
/// walk would need. What `Operation.toString()` does give is the printed
/// query/mutation text, which names the operation on its first line, so this
/// looks for `query <Name>` or `mutation <Name>` there instead. The trailing
/// `\b` keeps `StartStreamingSession` from matching
/// `StartStreamingSessionLegacy`.
///
/// A screen that fires several independent queries at once (see
/// `runIsolated`) can no longer be scripted by a `StubLink.responses` list
/// keyed on call order -- concurrent dispatch does not preserve it. This is
/// the per-operation replacement: build a `StubLink((request, _) => ...)`
/// that branches on this instead.
bool isOperation(Request request, String name) =>
    RegExp(r'(?:query|mutation)\s+' + RegExp.escape(name) + r'\b')
        .hasMatch(request.operation.toString());

/// A GraphQL-level failure response (the shape a server error takes).
Response graphqlErrorResponse(String message) => Response(
      errors: [GraphQLError(message: message)],
      response: const <String, dynamic>{},
    );
