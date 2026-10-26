/// The failures a source reports, in terms a screen can act on.
///
/// This library words nothing for the viewer. A screen formats a failure with
/// `AppLocalizations.sourceError`; [SourceException.toString] is English on
/// purpose, for logs and diagnostics only.
library;

enum SourceErrorKind {
  unreachable,
  unauthorized,
  notFound,
  unsupported,
  server,
  wrongPin,
}

/// A failure the app itself recognised and can word in the viewer's language,
/// as opposed to text a server sent. Each carries the English sentence used
/// for logs; `{detail}` stands for [SourceException.detail].
enum SourceFault {
  serverGone(
      'This server is no longer on this device.'), // l10n-ignore log text
  serverRefused('The server refused access to this.'), // l10n-ignore log text
  serverHttp('The server answered HTTP {detail}.'), // l10n-ignore log text
  serverUnreadable(
      'The server sent a response this app cannot read.'), // l10n-ignore log text
  serverNoData('The server sent no data.'), // l10n-ignore log text
  noFileToDownload(
      'This server offers no file to download for this item.'), // l10n-ignore log text
  mydiaBadServerId(
      'This server reports an id this app cannot use.'), // l10n-ignore log text
  mydiaWrongServerCode(
      'That code belongs to a different server.'), // l10n-ignore log text
  mydiaNoServerId(
      'This server did not say which server it is.'), // l10n-ignore log text
  jellyfinNoSession(
      'Jellyfin signed you in but sent no session.'), // l10n-ignore log text
  jellyfinNoQuickConnectCode(
      'Jellyfin did not hand out a Quick Connect code.'), // l10n-ignore log text
  jellyfinUnexpectedSignIn(
      'Jellyfin sent an unexpected sign-in reply.'), // l10n-ignore log text
  jellyfinNotJellyfin('This is not a Jellyfin server.'), // l10n-ignore log text
  jellyfinUnreadable(
      'The Jellyfin server sent a response this app cannot read.'), // l10n-ignore log text
  jellyfinNotAllowed(
      'Your Jellyfin account is not allowed to play this.'), // l10n-ignore log text
  jellyfinNoCompatibleStream(
      'Jellyfin found no way to play this file on this device.'), // l10n-ignore log text
  jellyfinRateLimited(
      'Jellyfin limits how much this account can stream right now.'), // l10n-ignore log text
  jellyfinRefused(
      'Jellyfin refused to play this ({detail}).'), // l10n-ignore log text
  plexUnreadable(
      'The Plex server sent a response this app cannot read.'), // l10n-ignore log text
  plexTvUnexpected('plex.tv sent an unexpected reply.'), // l10n-ignore log text
  plexNoDirectFile(
      'Plex offers no direct file for this item.'), // l10n-ignore log text
  plexNoServersForUser(
      'This user has no access to the servers on this account.'), // l10n-ignore log text
  plexRefusedConvert(
      'Plex refused to convert this file.'), // l10n-ignore log text
  stashUnreadable(
      'The server sent a response this app cannot read.'), // l10n-ignore log text
  stashHttp('Stash answered HTTP {detail}.'), // l10n-ignore log text
  stashUnexpectedReply(
      'Stash sent an unexpected reply.'), // l10n-ignore log text
  stashReportedError('Stash reported an error.'), // l10n-ignore log text
  stashStatus('Stash reports status {detail}.'), // l10n-ignore log text
  stashNotConfirmed(
      'Stash did not confirm the saved progress.'); // l10n-ignore log text

  const SourceFault(this.logText);

  final String logText;
}

class SourceException implements Exception {
  const SourceException(this.kind, [this.message])
      : fault = null,
        detail = null;

  const SourceException._fault(this.kind, SourceFault this.fault, this.detail)
      : message = null;

  const SourceException.unreachable() : this(SourceErrorKind.unreachable);
  const SourceException.unauthorized() : this(SourceErrorKind.unauthorized);
  const SourceException.notFound() : this(SourceErrorKind.notFound);
  const SourceException.unsupported([String? message])
      : this(SourceErrorKind.unsupported, message);

  /// [message] is the server's own words; for the app's own failures use
  /// [SourceException.fault].
  const SourceException.server(String message)
      : this(SourceErrorKind.server, message);

  /// plex.tv refused a Plex Home user's PIN.
  const SourceException.wrongPin() : this(SourceErrorKind.wrongPin);

  /// A server failure the app recognised itself. [detail] fills the
  /// `{detail}` of the sentence (an HTTP status, a server's status word).
  const SourceException.fault(SourceFault fault, {String? detail})
      : this._fault(SourceErrorKind.server, fault, detail);

  /// Like [SourceException.fault], for something the server cannot do.
  const SourceException.unsupportedFault(SourceFault fault)
      : this._fault(SourceErrorKind.unsupported, fault, null);

  final SourceErrorKind kind;

  /// For [SourceErrorKind.server], the server's own words. Never a token.
  /// Null for a [fault]: the screen words that in the viewer's language.
  final String? message;

  /// Set when the app itself, not the server, produced this failure.
  final SourceFault? fault;

  /// The value a [fault]'s sentence names.
  final String? detail;

  /// English text for logs and diagnostics; never shown to a viewer.
  String get logText {
    final fault = this.fault;
    if (fault != null) {
      return fault.logText.replaceAll('{detail}', detail ?? '');
    }
    final message = this.message;
    if (message != null) return message;
    return switch (kind) {
      SourceErrorKind.unreachable =>
        'Could not reach this server.', // l10n-ignore log text
      SourceErrorKind.unauthorized =>
        'This server no longer accepts the saved sign-in.', // l10n-ignore log text
      SourceErrorKind.notFound =>
        'This item is no longer on the server.', // l10n-ignore log text
      SourceErrorKind.unsupported =>
        'This server does not support that.', // l10n-ignore log text
      SourceErrorKind.server =>
        'The server reported an error.', // l10n-ignore log text
      SourceErrorKind.wrongPin =>
        'That PIN is not right.', // l10n-ignore log text
    };
  }

  @override
  String toString() => logText;
}
