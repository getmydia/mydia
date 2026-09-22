/// Secret shapes removed from both crash reports and log lines.
///
/// `crash_sanitizer.dart` applies these and goes much further (hosts, URLs,
/// home directories, long tokens). `log_redactor.dart` applies these and
/// little else, on purpose.
library;

final bearerPattern = RegExp(r'Bearer\s+[a-zA-Z0-9_\-.]+');
final jwtPattern = RegExp(r'eyJ[\w-]+\.[\w-]+\.[\w-]+');
final passwordPattern =
    RegExp(r'''password["\s:=]+[^\s"]+''', caseSensitive: false);
final secretPattern =
    RegExp(r'''secret["\s:=]+[^\s"]+''', caseSensitive: false);
final apiKeyPattern =
    RegExp(r'''api_key["\s:=]+[^\s"]+''', caseSensitive: false);
