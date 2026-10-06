/// Decoupled schema downgrade inspection for Mydia GraphQL queries.
library;

import '../../../domain/sources/source_error.dart';

/// Whether [error] is the server rejecting a field this client asked for.
///
/// A player installed independently of its server (APK, Flatpak) can be newer
/// than the server it talks to. GraphQL validates the whole document up front,
/// so one unknown field fails the entire query rather than degrading. Fallback
/// queries omit newer fields when this occurs.
bool isUnknownFieldError(Object error) {
  final message = error is SourceException ? error.message : error.toString();
  return message != null && message.contains('Cannot query field');
}
