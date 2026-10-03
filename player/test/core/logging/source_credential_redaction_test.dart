import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/crash_reporting/crash_sanitizer.dart';
import 'package:player/core/logging/log_redactor.dart';

void main() {
  const lines = [
    'GET https://plex.test/library?X-Plex-Token=plexsecret42&x=1',
    'headers: {X-Plex-Token: plexsecret42, Accept: application/json}',
    'ApiKey: stashsecret42',
    '{"ApiKey": "stashsecret42"}',
    'apikey=stashsecret42',
  ];

  for (final line in lines) {
    test('log redaction removes the credential from: $line', () {
      final out = redactLogMessage(line);
      expect(out, isNot(contains('plexsecret42')));
      expect(out, isNot(contains('stashsecret42')));
    });

    test('crash sanitizing removes the credential from: $line', () {
      final out = sanitizeString(line);
      expect(out, isNot(contains('plexsecret42')));
      expect(out, isNot(contains('stashsecret42')));
    });
  }
}
