import 'package:graphql_flutter/graphql_flutter.dart';

/// Whether [exception] is the server rejecting a field this client asked for.
///
/// A player installed independently of its server (APK, Flatpak) can be newer
/// than the server it talks to. GraphQL validates the whole document up front,
/// so one unknown field fails the entire query rather than degrading. Watchers
/// use this to fall back to a document that omits newer fields.
///
/// The message is pinned by a server-side test in `schema_test.exs`; if
/// Absinthe rephrases it, that test fails in the same change.
bool isUnknownFieldError(OperationException exception) {
  return exception.graphqlErrors.any(
    (error) => error.message.contains('Cannot query field'),
  );
}
