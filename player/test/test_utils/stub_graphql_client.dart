import 'package:graphql_flutter/graphql_flutter.dart';

/// Returns the response for the [callIndex]-th request, or an [Exception] to
/// throw, or a fully built [Response].
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

    final outcome = handler(request, index);
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
    );

/// A GraphQL-level failure response (the shape a server error takes).
Response graphqlErrorResponse(String message) => Response(
      errors: [GraphQLError(message: message)],
      response: const <String, dynamic>{},
    );
