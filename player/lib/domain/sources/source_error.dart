/// The failures a source reports, in terms a screen can act on.
library;

enum SourceErrorKind {
  unreachable,
  unauthorized,
  notFound,
  unsupported,
  server
}

class SourceException implements Exception {
  const SourceException(this.kind, [this.message]);

  const SourceException.unreachable() : this(SourceErrorKind.unreachable);
  const SourceException.unauthorized() : this(SourceErrorKind.unauthorized);
  const SourceException.notFound() : this(SourceErrorKind.notFound);
  const SourceException.unsupported([String? message])
      : this(SourceErrorKind.unsupported, message);
  const SourceException.server(String message)
      : this(SourceErrorKind.server, message);

  final SourceErrorKind kind;

  /// For [SourceErrorKind.server], the server's own words. Never a token.
  final String? message;

  String get viewerMessage => switch (kind) {
        SourceErrorKind.unreachable =>
          'Could not reach this server. Check that it is running and on '
              'the network.',
        SourceErrorKind.unauthorized =>
          'This server no longer accepts the saved sign-in. Sign in again.',
        SourceErrorKind.notFound => 'This item is no longer on the server.',
        SourceErrorKind.unsupported =>
          message ?? 'This server does not support that.',
        SourceErrorKind.server => message ?? 'The server reported an error.',
      };

  /// The viewer message: the player screen shows a load failure as
  /// `e.toString()`, and a refused Plex transcode must reach the viewer in
  /// the server's own words.
  @override
  String toString() => viewerMessage;
}
