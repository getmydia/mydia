import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/logging/log_redactor.dart';

void main() {
  group('removes', () {
    const cases = {
      'GET https://mydia.example/hls/master.m3u8?token=abc123&quality=hd':
          'GET https://mydia.example/hls/master.m3u8?token=[REDACTED]&quality=hd',
      'refresh with ?access_token=abc&refresh_token=xyz':
          'refresh with ?access_token=[REDACTED]&refresh_token=[REDACTED]',
      'https://x.example/a?Token=ABC': 'https://x.example/a?Token=[REDACTED]',
      'Authorization: Bearer abc.def.ghi': 'Authorization: [REDACTED]',
      'headers: {authorization: Basic dXNlcjpwYXNz}':
          'headers: {authorization: [REDACTED]}',
      'Retrying with Bearer abc.def-123': 'Retrying with Bearer [REDACTED]',
      'Connecting to https://admin:hunter2@nas.local:8443/api':
          'Connecting to https://[REDACTED]@nas.local:8443/api',
      'login failed: {"username":"sam","password":"hunter2"}':
          'login failed: {"username":"sam","password: [REDACTED]"}',
      'api_key=live_4f9a': 'api_key: [REDACTED]',
      'jwt eyJhbGciOi.eyJzdWIi.c2lnbmF0dXJl here': 'jwt [REDACTED] here',
      'login failed: {"username":"sam","password":"hunter 2 words"}':
          'login failed: {"username":"sam","password: [REDACTED]"}',
      "retry with {secret: 'two words here'}": 'retry with {secret: [REDACTED]',
      'headers: {"token": "abc def"}': 'headers: {"token": "[REDACTED]"}',
    };

    for (final MapEntry(key: input, value: expected) in cases.entries) {
      test(input, () => expect(redactLogMessage(input), expected));
    }
  });

  group('keeps', () {
    const kept = [
      '[P2P] Host started with NodeID: 3f8a9c2e7b1d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2c4e6b8d0f2a4c6e8b0d2f4a',
      'Playing /media/Series/The Lantern Keepers/S01E02.mkv (sha256 9f2c4e6a8b0d1e3f5a7c9e1b3d5f7a9c)',
      'GET https://mydia.example:4443/api/graphql?operation=Library',
      'https://x.example/a?monkey=3&keyframe=12',
      'Relay connected: https://cae1-1.relay.mydia.dev',
    ];

    for (final line in kept) {
      test(line, () => expect(redactLogMessage(line), line));
    }
  });
}
