/// Scrubs a crash report before it leaves the device.
///
/// A port of the server's `Mydia.CrashReporter.Sanitizer`
/// (`lib/mydia/crash_reporter/sanitizer.ex`), plus rules for what a player
/// error carries that a server error does not: the address of the user's own
/// server, and stream URLs with tokens in their query strings.
///
/// As on the server, free text gets every rule and frame fields get only the
/// home-directory rule. Frame files are package URIs, and redacting a long
/// class name out of a function would break grouping on the relay.
library;

/// Longest `error_message` sent, matching relay-worker's `MAX_MESSAGE_CHARS`.
///
/// Applied after redaction, so a cut can never split a secret into a fragment
/// the patterns no longer recognise.
const int kMaxCrashMessageChars = 4096;

const _truncationMarker = '...[truncated]';

final _homeUnix = RegExp(r'/home/[^/\s]+');
final _homeMac = RegExp(r'/Users/[^/\s]+');
final _homeWindows = RegExp(r'C:\\Users\\[^\\:\s]+');

// scheme://authority path ?query #fragment. The authority must be non-empty,
// so file:///home/... is left to the home-directory rules.
final _url = RegExp(
  r'''([a-zA-Z][a-zA-Z0-9+.\-]*)://([^\s/?#<>"']+)([^\s?#<>"']*)(\?[^\s#<>"']*)?(#[^\s<>"']*)?''',
);
final _hostAndPort = RegExp(r'^(\[[^\]]*\]|[^:]*)(:\d+)?$');

// dart:io's SocketException names the host outside any URL.
final _hostLookup = RegExp(r"Failed host lookup: '([^']*)'");
final _socketAddress = RegExp(r'address = ([^,\s)]+)');

final _bearer = RegExp(r'Bearer\s+[a-zA-Z0-9_\-.]+');
final _jwt = RegExp(r'eyJ[\w-]+\.[\w-]+\.[\w-]+');
final _longToken = RegExp(r'[a-zA-Z0-9_-]{32,}');
final _digit = RegExp(r'[0-9]');
final _password = RegExp(r'''password["\s:=]+[^\s"]+''', caseSensitive: false);
final _secret = RegExp(r'''secret["\s:=]+[^\s"]+''', caseSensitive: false);
final _apiKey = RegExp(r'''api_key["\s:=]+[^\s"]+''', caseSensitive: false);

const _sensitiveKeyParts = [
  'password',
  'secret',
  'api_key',
  'apikey',
  'token',
  'auth',
  'bearer',
  'credentials',
  'private_key',
  'private',
  'key',
  'jwt',
  'session',
  'cookie',
];

/// Returns a copy of [report] that is safe to send.
///
/// Rewrites `error_message`, each `stacktrace` entry's `file`, and the string
/// values of the flat `metadata` map. Every other key passes through.
Map<String, Object?> sanitizeReport(Map<String, Object?> report) {
  final out = Map<String, Object?>.of(report);

  final message = out['error_message'];
  if (message is String)
    out['error_message'] = _truncate(sanitizeString(message));

  final frames = out['stacktrace'];
  if (frames is List) {
    out['stacktrace'] = [
      for (final frame in frames)
        frame is Map<String, Object?> ? _sanitizeFrame(frame) : frame,
    ];
  }

  final metadata = out['metadata'];
  if (metadata is Map<String, Object?>) {
    out['metadata'] = {
      for (final entry in metadata.entries)
        entry.key: _sanitizeMetadataValue(entry.key, entry.value),
    };
  }

  return out;
}

/// Applies every free-text rule to [input].
String sanitizeString(String input) {
  var out = redactHomeDirectories(input);
  out = out.replaceAllMapped(_url, _rewriteUrl);
  out = out.replaceAllMapped(
    _hostLookup,
    (m) => "Failed host lookup: '${_redactHost(m[1]!)}'",
  );
  out = out.replaceAllMapped(
    _socketAddress,
    (m) => 'address = ${_redactHost(m[1]!)}',
  );
  out = out.replaceAll(_bearer, 'Bearer [REDACTED]');
  out = out.replaceAll(_jwt, '[REDACTED]');
  // The server redacts every 32+ run. The player also requires a digit:
  // Dart class names run past 32 characters in most framework errors, while
  // keys, session tokens and node ids essentially always contain one.
  out = out.replaceAllMapped(
    _longToken,
    (m) => _digit.hasMatch(m[0]!) ? '[REDACTED]' : m[0]!,
  );
  out = out.replaceAll(_password, 'password: [REDACTED]');
  out = out.replaceAll(_secret, 'secret: [REDACTED]');
  out = out.replaceAll(_apiKey, 'api_key: [REDACTED]');
  return out;
}

/// Replaces the username in Unix, macOS and Windows home directories.
String redactHomeDirectories(String input) => input
    .replaceAll(_homeUnix, '/home/[USER]')
    .replaceAll(_homeMac, '/Users/[USER]')
    .replaceAll(_homeWindows, r'C:\Users\[USER]');

Map<String, Object?> _sanitizeFrame(Map<String, Object?> frame) {
  final out = Map<String, Object?>.of(frame);
  final file = out['file'];
  if (file is String) out['file'] = redactHomeDirectories(file);
  return out;
}

// `file` and `function` in metadata repeat the top frame, so they follow the
// frame rules rather than the free-text ones.
Object? _sanitizeMetadataValue(String key, Object? value) {
  if (value is! String) return value;
  if (key == 'function') return value;
  if (key == 'file') return redactHomeDirectories(value);
  if (_isSensitiveKey(key)) return '[REDACTED]';
  return sanitizeString(value);
}

bool _isSensitiveKey(String key) {
  final lower = key.toLowerCase();
  return _sensitiveKeyParts.any(lower.contains);
}

String _rewriteUrl(Match m) {
  final scheme = m[1]!;
  final authority = m[2]!;
  final path = m[3] ?? '';
  final query = m[4];

  final at = authority.lastIndexOf('@');
  final userinfo = at >= 0 ? '[REDACTED]:[REDACTED]@' : '';
  final hostAndPort = at >= 0 ? authority.substring(at + 1) : authority;

  final parts = _hostAndPort.firstMatch(hostAndPort);
  final host =
      parts == null ? '[HOST]' : '${_redactHost(parts[1]!)}${parts[2] ?? ''}';

  return '$scheme://$userinfo$host$path${query == null ? '' : '?[REDACTED]'}';
}

// mydia.dev is ours, and loopback is where the player's own HLS proxy
// listens. Every other host is the user's.
String _redactHost(String host) {
  final lower = host.toLowerCase();
  final kept = lower == 'mydia.dev' ||
      lower.endsWith('.mydia.dev') ||
      lower == 'localhost' ||
      lower == '127.0.0.1' ||
      lower == '::1' ||
      lower == '[::1]';
  return kept ? host : '[HOST]';
}

String _truncate(String value) => value.length <= kMaxCrashMessageChars
    ? value
    : '${value.substring(0, kMaxCrashMessageChars)}$_truncationMarker';
