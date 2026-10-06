import 'package:graphql_flutter/graphql_flutter.dart';

import '../../sources/mydia/schema_downgrade.dart' as source_downgrade;

/// Whether [error] is the server rejecting a field this client asked for.
///
/// A player installed independently of its server (APK, Flatpak) can be newer
/// than the server it talks to. GraphQL validates the whole document up front,
/// so one unknown field fails the entire query rather than degrading. Watchers
/// use this to fall back to a document that omits newer fields.
///
/// Preserves compatibility for legacy callers expecting [isUnknownFieldError].
bool isUnknownFieldError(Object error) {
  if (error is OperationException) {
    return error.graphqlErrors.any(
      (err) => err.message.contains('Cannot query field'),
    );
  }
  return source_downgrade.isUnknownFieldError(error);
}
