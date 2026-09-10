import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/crash_reporting/crash_report.dart';

const _context = CrashAppContext(
  version: '0.52.1',
  buildNumber: '5201',
  platform: 'android',
  osVersion: 'Android 15 (SDK 35)',
  environment: 'prod',
);

// What an AOT release build prints: no column, and <asynchronous suspension>
// between frames. Captured from a real ahead-of-time compiled probe.
const _releaseTrace = '''
#0      PlayerController.seek (package:player/core/player/player_controller.dart:412)
<asynchronous suspension>
#1      _PlayerScreenState._onSeek (package:player/presentation/screens/player/player_screen.dart:2201)
<asynchronous suspension>
''';

void main() {
  group('parseCrashFrames', () {
    test('reads function, file and line from a release trace', () {
      final frames = parseCrashFrames(StackTrace.fromString(_releaseTrace));

      expect(frames.map((f) => f.toJson()), [
        {
          'function': 'PlayerController.seek',
          'file': 'package:player/core/player/player_controller.dart',
          'line': 412,
        },
        {
          'function': '_PlayerScreenState._onSeek',
          'file':
              'package:player/presentation/screens/player/player_screen.dart',
          'line': 2201,
        },
      ]);
    });

    test('drops leading framework frames so frame 0 is player code', () {
      final frames = parseCrashFrames(StackTrace.fromString('''
#0      State.setState (package:flutter/src/widgets/framework.dart:1219:9)
#1      _DownloadsScreenState._onProgress (package:player/presentation/screens/downloads/downloads_screen.dart:88:5)
#2      _rootRunUnary (dart:async/zone.dart:1538:47)
'''));

      expect(frames.map((f) => f.file), [
        'package:player/presentation/screens/downloads/downloads_screen.dart',
        'dart:async/zone.dart',
      ]);
      expect(frames.first.line, 88);
    });

    test('keeps a trace with no player frame whole', () {
      final frames = parseCrashFrames(StackTrace.fromString('''
#0      RenderFlex.performLayout (package:flutter/src/rendering/flex.dart:1016:32)
#1      RenderObject.layout (package:flutter/src/rendering/object.dart:2656:7)
'''));

      expect(frames, hasLength(2));
      expect(frames.first.file, 'package:flutter/src/rendering/flex.dart');
    });

    test('names closures and skips the VM fold marker', () {
      final frames = parseCrashFrames(StackTrace.fromString('''
#0      _PlayerScreenState.build.<anonymous closure> (package:player/presentation/screens/player/player_screen.dart:900:13)
...
#1      _InkResponseState.handleTap (package:flutter/src/material/ink_well.dart:1224:21)
'''));

      expect(frames.map((f) => f.function), [
        '_PlayerScreenState.build.<fn>',
        '_InkResponseState.handleTap',
      ]);
    });

    test('keeps at most 64 frames, from the top', () {
      final trace = [
        for (var i = 0; i < 100; i++)
          '#$i      F$i (package:player/f.dart:${i + 1})',
      ].join('\n');

      final frames = parseCrashFrames(StackTrace.fromString(trace));

      expect(frames, hasLength(kMaxCrashFrames));
      expect(frames.first.line, 1);
    });

    test('parses a live stack trace', () {
      final frames = parseCrashFrames(StackTrace.current);

      expect(frames, isNotEmpty);
      expect(frames.every((f) => f.line > 0), isTrue);
    });

    test('returns no frames without a stack', () {
      expect(parseCrashFrames(null), isEmpty);
    });
  });

  group('CrashReport', () {
    test('serializes to the body both relays accept', () {
      final report = CrashReport.fromError(
        StateError('No element'),
        StackTrace.fromString(_releaseTrace),
        capture: CrashCapture.zone,
        context: _context,
        occurredAt: DateTime.utc(2026, 9, 10, 12),
      );

      // Mirrors PLAYER_REPORT in relay-worker/test/crashes/ingest.test.ts.
      expect(report.toJson(), {
        'source': 'player',
        'error_type': 'StateError',
        'error_message': 'Bad state: No element',
        'stacktrace': [
          {
            'function': 'PlayerController.seek',
            'file': 'package:player/core/player/player_controller.dart',
            'line': 412,
          },
          {
            'function': '_PlayerScreenState._onSeek',
            'file':
                'package:player/presentation/screens/player/player_screen.dart',
            'line': 2201,
          },
        ],
        'version': '0.52.1',
        'environment': 'prod',
        'occurred_at': '2026-09-10T12:00:00.000Z',
        'metadata': {
          'capture': 'zone',
          'manual': false,
          'platform': 'android',
          'os_version': 'Android 15 (SDK 35)',
          'build_number': '5201',
          'function': 'PlayerController.seek',
          'file': 'package:player/core/player/player_controller.dart',
          'line': 412,
        },
      });
    });

    test('omits the top-frame metadata when there is no stack', () {
      final json = CrashReport.fromError(
        Exception('boom'),
        null,
        capture: CrashCapture.startup,
        context: _context,
        occurredAt: DateTime.utc(2026, 9, 10, 12),
        manual: true,
      ).toJson();

      expect(json['stacktrace'], isEmpty);
      expect(json['metadata'], {
        'capture': 'startup',
        'manual': true,
        'platform': 'android',
        'os_version': 'Android 15 (SDK 35)',
        'build_number': '5201',
      });
    });

    test('writes occurred_at in UTC', () {
      final json = CrashReport.fromError(
        Exception('boom'),
        null,
        capture: CrashCapture.zone,
        context: _context,
        occurredAt: DateTime.utc(2026, 9, 10, 12).toLocal(),
      ).toJson();

      expect(json['occurred_at'], '2026-09-10T12:00:00.000Z');
    });

    test('uses the wire names the relay stores', () {
      expect(CrashCapture.values.map((c) => c.wireName), [
        'flutter_error',
        'zone',
        'platform_dispatcher',
        'startup',
      ]);
    });
  });

  group('crashDedupKey', () {
    test('keys on type and top frame when there are frames', () {
      expect(
        crashDedupKey({
          'error_type': 'StateError',
          'error_message': 'anything',
          'stacktrace': [
            {'function': 'F', 'file': 'package:player/f.dart', 'line': 7},
          ],
        }),
        'StateError|package:player/f.dart|7',
      );
    });

    test('keys on type and the first 200 message characters otherwise', () {
      final message = 'x' * 300;

      expect(
        crashDedupKey({
          'error_type': 'StateError',
          'error_message': message,
          'stacktrace': <Object?>[],
        }),
        'StateError|${'x' * 200}',
      );
    });
  });
}
