/// What the player strips from a log line before it is written anywhere.
///
/// Secrets only. Unlike `crash_sanitizer.dart`, this keeps hosts, URLs, IPs,
/// node IDs, file hashes and titles: they are what an investigation needs, and
/// the Diagnostics screen tells the user they are shared. The crash
/// sanitizer's 32+ character token rule in particular would erase every node
/// ID and hash.
library;

import 'secret_patterns.dart';

// user:pass@ in a URL's authority.
final _userinfo =
    RegExp(r'''([a-zA-Z][a-zA-Z0-9+.\-]*://)[^\s/?#@:"']+:[^\s/?#@"']*@''');

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

String redactLogMessage(String input) {
  var out = input.replaceAllMapped(_userinfo, (m) => '${m[1]}[REDACTED]@');
  out = out.replaceAllMapped(_credentialParam, (m) => '${m[1]}[REDACTED]');
  out = out.replaceAllMapped(_authorization, (m) => '${m[1]}[REDACTED]');
  out = out.replaceAll(bearerPattern, 'Bearer [REDACTED]');
  out = out.replaceAll(jwtPattern, '[REDACTED]');
  out = out.replaceAll(passwordPattern, 'password: [REDACTED]');
  out = out.replaceAll(secretPattern, 'secret: [REDACTED]');
  out = out.replaceAll(apiKeyPattern, 'api_key: [REDACTED]');
  return out;
}
