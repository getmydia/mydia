/// What the player strips from a log line before it is written anywhere.
///
/// Secrets only. Unlike `crash_sanitizer.dart`, this keeps hosts, URLs, IPs,
/// node IDs, file hashes and titles: they are what an investigation needs, and
/// the Diagnostics screen tells the user they are shared. The crash
/// sanitizer's 32+ character token rule in particular would erase every node
/// ID and hash.
///
/// A quoted credential value is redacted whole, however many words it has:
/// the closing quote, not whitespace, ends the match, so `"password":
/// "hunter 2 words"` loses every word of it. An unquoted value
/// (`password: hunter 2 words`, no quotes anywhere) is still cut at the
/// first space. That is deliberate, not an oversight: without a quote
/// marking where the value ends, the only way to redact the secret without
/// also eating the rest of the line is to stop at whitespace, and the rest
/// of the line is the context a log line exists to keep.
library;

import 'secret_patterns.dart';

// A credential key whose value is quoted: the quotes, not whitespace, end
// the value, so a secret with spaces in it cannot survive in fragments. Runs
// before every other rule, including the shared patterns, so the value is
// already gone by the time they see the line. The replacement keeps the
// value's own quote character (rather than a bare marker) so the shared
// patterns that still run afterward see the same shape a short, unquoted
// match would have left them, instead of tripping over a stray bracket.
final _quotedCredential = RegExp(
  r'''(["']?(?:password|passwd|secret|api_key|apikey|token)["']?\s*[:=]\s*)("[^"]*"|'[^']*')''',
  caseSensitive: false,
);

// user:pass@ in a URL's authority. Every variable-length part -- the scheme
// suffix, the user and the password -- is bounded (real schemes, usernames
// and passwords are all short) rather than left open with `+`/`*`: on a
// line with no `@` at all, an unbounded quantifier backtracks character by
// character over the rest of the line looking for one that never comes,
// which is quadratic in the line's length. That happens for the scheme
// suffix just as it does for the user/password parts -- a long run of plain
// letters (a base64 blob, a hex hash) after "https:" matches
// `[a-zA-Z0-9+.\-]*` too, so without a bound on it the engine retries the
// same doomed backtrack starting at every letter in the run. Bounding all
// three gives up after a fixed amount of work per attempted match instead
// of scanning to the end of the line.
final _userinfo = RegExp(
  r'''([a-zA-Z][a-zA-Z0-9+.\-]{0,31}://)[^\s/?#@:"']{1,128}:[^\s/?#@"']{0,128}@''',
);

// The value of a credential-bearing query parameter.
final _credentialParam = RegExp(
  r'''([?&](?:token|access_token|refresh_token|api_key|apikey|key|password|auth)=)[^&#\s"']*''',
  caseSensitive: false,
);

// An Authorization header's value, with or without its scheme.
final _authorization = RegExp(
  r'''(authorization["']?\s*[:=]\s*["']?)(?:(?:bearer|basic)\s+)?[^\s"',}]+''',
  caseSensitive: false,
);

// An unquoted token-family assignment: `token:`, `access_token=`,
// `refresh_token = `, `auth_token:`, optionally with a quoted key. The
// mandatory `[:=]` is what keeps this from matching prose that merely
// mentions the word, like "Access token refreshed" -- there is no separator
// to require there, so it never matches. A quoted value under these same
// key names is already gone by the time this runs, redacted whole by
// `_quotedCredential` above; a `?token=`/`&token=` value is already gone
// too, redacted by `_credentialParam`. Excluding `&` from the value here
// keeps this rule from re-absorbing the rest of a query string that rule
// already redacted, so re-matching an already-redacted value is a harmless
// no-op rather than a second bite out of the line.
final _unquotedToken = RegExp(
  r'''(["']?(?:access_token|refresh_token|auth_token|token)["']?\s*[:=]\s*)[^\s"',}&]+''',
  caseSensitive: false,
);

String redactLogMessage(String input) {
  var out = input.replaceAllMapped(
    _quotedCredential,
    (m) => '${m[1]}${m[2]![0]}[REDACTED]${m[2]![0]}',
  );
  out = out.replaceAllMapped(_userinfo, (m) => '${m[1]}[REDACTED]@');
  out = out.replaceAllMapped(_credentialParam, (m) => '${m[1]}[REDACTED]');
  out = out.replaceAllMapped(_authorization, (m) => '${m[1]}[REDACTED]');
  out = out.replaceAllMapped(_unquotedToken, (m) => '${m[1]}[REDACTED]');
  out = out.replaceAll(bearerPattern, 'Bearer [REDACTED]');
  out = out.replaceAll(jwtPattern, '[REDACTED]');
  out = out.replaceAll(passwordPattern, 'password: [REDACTED]');
  out = out.replaceAll(secretPattern, 'secret: [REDACTED]');
  out = out.replaceAll(apiKeyPattern, 'api_key: [REDACTED]');
  return out;
}
