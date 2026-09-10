import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/crash_reporting/crash_sanitizer.dart';

void main() {
  // Ported from test/mydia/crash_reporter/sanitizer_test.exs, so the player
  // redacts at least what the server does. Cases whose expectation differs
  // from the server say why.
  group('sanitizeString, server parity', () {
    test('redacts usernames in Unix, macOS and Windows paths', () {
      expect(
        sanitizeString('File not found: /home/user/mydia/data/file.txt'),
        'File not found: /home/[USER]/mydia/data/file.txt',
      );
      expect(
        sanitizeString('Cannot read /Users/jane/Library/Caches/x'),
        'Cannot read /Users/[USER]/Library/Caches/x',
      );
      expect(
        sanitizeString(r'Access denied: C:\Users\john\Documents\file.txt'),
        r'Access denied: C:\Users\[USER]\Documents\file.txt',
      );
    });

    test('keeps paths without usernames', () {
      expect(
        sanitizeString('Error in /app/lib/mydia/app.ex:42'),
        'Error in /app/lib/mydia/app.ex:42',
      );
    });

    test('redacts API keys', () {
      expect(
        sanitizeString('API key abc123def456ghi789jkl012mno345pqr is invalid'),
        'API key [REDACTED] is invalid',
      );
    });

    test('redacts bearer tokens', () {
      expect(
        sanitizeString('Authentication failed with Bearer abc123def456ghi789'),
        'Authentication failed with Bearer [REDACTED]',
      );
    });

    test('redacts JWTs', () {
      expect(
        sanitizeString(
          'Invalid token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
          'eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
          'dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
        ),
        'Invalid token: [REDACTED]',
      );
    });

    test('redacts password values', () {
      expect(
        sanitizeString('Database connection failed: password: secret123'),
        'Database connection failed: password: [REDACTED]',
      );
    });

    test('redacts URL credentials, and the host as well on the player', () {
      expect(
        sanitizeString(
          'Failed to connect to https://user:pass123@example.com/api',
        ),
        'Failed to connect to https://[REDACTED]:[REDACTED]@[HOST]/api',
      );
    });

    test('redacts connection-string credentials and keeps localhost', () {
      expect(
        sanitizeString(
          'Connection failed: postgres://user:password@localhost/db',
        ),
        'Connection failed: postgres://[REDACTED]:[REDACTED]@localhost/db',
      );
    });

    test('keeps bare IP addresses', () {
      expect(
        sanitizeString('Connection from 192.168.1.100 denied'),
        'Connection from 192.168.1.100 denied',
      );
    });
  });

  group('sanitizeString, player rules', () {
    test('redacts the host and query of a stream URL, keeping the port', () {
      expect(
        sanitizeString(
          'GET https://mydia.example.org:4443/api/stream/7/index.m3u8'
          '?token=abc123 failed',
        ),
        'GET https://[HOST]:4443/api/stream/7/index.m3u8?[REDACTED] failed',
      );
    });

    test('drops URL fragments', () {
      expect(
        sanitizeString('at http://10.0.0.4:4000/player#/settings'),
        'at http://[HOST]:4000/player',
      );
    });

    test('keeps mydia.dev hosts and loopback', () {
      const relay = 'POST https://relay.mydia.dev/crashes/report timed out';
      const proxy = 'GET http://127.0.0.1:53412/hls/master.m3u8 failed';
      expect(sanitizeString(relay), relay);
      expect(sanitizeString(proxy), proxy);
      expect(
        sanitizeString('http://[::1]:8080/x'),
        'http://[::1]:8080/x',
      );
    });

    test("redacts the host in dart:io's SocketException wording", () {
      expect(
        sanitizeString(
          "SocketException: Failed host lookup: 'mydia.example.org' "
          '(OS Error: No address associated with hostname, errno = 7)',
        ),
        "SocketException: Failed host lookup: '[HOST]' "
        '(OS Error: No address associated with hostname, errno = 7)',
      );
      expect(
        sanitizeString(
          'SocketException: Connection refused (OS Error: Connection '
          'refused, errno = 111), address = 192.168.1.5, port = 43210',
        ),
        'SocketException: Connection refused (OS Error: Connection '
        'refused, errno = 111), address = [HOST], port = 43210',
      );
    });

    test('keeps long identifiers with no digit', () {
      const message = 'setState() called after dispose(): '
          '_OfflineSentinelStreamingFallbackState#1a2b3';
      expect(sanitizeString(message), message);
    });

    test('redacts a 64-character hex node id', () {
      final nodeId = 'a1' * 32;
      expect(sanitizeString('dial $nodeId failed'), 'dial [REDACTED] failed');
    });

    test('leaves file URIs to the home-directory rule', () {
      expect(
        sanitizeString('file:///home/alex/.local/share/x.db locked'),
        'file:///home/[USER]/.local/share/x.db locked',
      );
    });

    test('redacts Windows profiles on any drive, separator and case', () {
      expect(
        sanitizeString(r'Cannot open D:\Users\alice\AppData\x.log'),
        r'Cannot open D:\Users\[USER]\AppData\x.log',
      );
      expect(
        sanitizeString(r'Cannot open c:\users\bob\y.db'),
        r'Cannot open c:\users\[USER]\y.db',
      );
      expect(
        sanitizeString('Cannot open file:///C:/Users/carol/z.db'),
        'Cannot open file:///C:/Users/[USER]/z.db',
      );
    });
  });

  group('sanitizeReport', () {
    test('sanitizes the message and truncates after redacting', () {
      final jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.'
          'c2lnbmF0dXJlMTIzNDU2Nzg5MA';
      final message = '${'a' * 4090} $jwt';

      final out = sanitizeReport({'error_message': message});
      final sanitized = out['error_message']! as String;

      expect(sanitized, isNot(contains('eyJ')));
      expect(sanitized, endsWith('...[truncated]'));
      expect(
        sanitized.length,
        kMaxCrashMessageChars + '...[truncated]'.length,
      );
    });

    test('leaves a short message untruncated', () {
      expect(
        sanitizeReport({'error_message': 'Bad state: No element'}),
        {'error_message': 'Bad state: No element'},
      );
    });

    test('redacts home directories in frame files and leaves functions', () {
      final out = sanitizeReport({
        'stacktrace': [
          {
            'function': '_OfflineSentinelStreamingFallbackState1234.build',
            'file': 'file:///home/alex/player/lib/x.dart',
            'line': 3,
          },
        ],
      });

      expect(out['stacktrace'], [
        {
          'function': '_OfflineSentinelStreamingFallbackState1234.build',
          'file': 'file:///home/[USER]/player/lib/x.dart',
          'line': 3,
        },
      ]);
    });

    test('applies frame rules to the metadata copy of the top frame', () {
      final out = sanitizeReport({
        'metadata': {
          'function': '_OfflineSentinelStreamingFallbackState1234.build',
          'file': '/home/alex/x.dart',
          'line': 3,
          'os_version': 'Android 15 (SDK 35)',
          'manual': false,
        },
      });

      expect(out['metadata'], {
        'function': '_OfflineSentinelStreamingFallbackState1234.build',
        'file': '/home/[USER]/x.dart',
        'line': 3,
        'os_version': 'Android 15 (SDK 35)',
        'manual': false,
      });
    });

    test('redacts metadata keys that look sensitive', () {
      final out = sanitizeReport({
        'metadata': {
          'api_key': 'secret123',
          'password': 'pass456',
          'secret_token': 'token789',
          'normal_value': 'ok',
        },
      });

      expect(out['metadata'], {
        'api_key': '[REDACTED]',
        'password': '[REDACTED]',
        'secret_token': '[REDACTED]',
        'normal_value': 'ok',
      });
    });

    test('passes through keys it has no rule for', () {
      final report = {
        'source': 'player',
        'error_type': 'StateError',
        'version': '0.52.1',
      };
      expect(sanitizeReport(report), report);
    });
  });
}
