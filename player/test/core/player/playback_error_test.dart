import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/playback_error.dart';

void main() {
  group('playbackErrorMessage', () {
    test('explains a source that would not open', () {
      final message = playbackErrorMessage(
        'Failed to open http://127.0.0.1:12345/direct/file-old/stream.',
      );

      expect(message, contains('Could not open this stream'));
      expect(
        message,
        contains('replaced'),
        reason: 'a replaced or deleted file is the common cause, and naming it '
            'is what turns a dead end into something the viewer can act on',
      );
    });

    test('matches regardless of how mpv cases the phrase', () {
      expect(
        playbackErrorMessage('FAILED TO OPEN whatever'),
        contains('Could not open this stream'),
      );
    });

    test('passes an unrecognised error through rather than swallowing it', () {
      final message = playbackErrorMessage('Audio device init failed');

      expect(message, contains('Audio device init failed'));
      expect(
        message,
        startsWith('Playback failed'),
        reason: 'an ugly message beats the black screen this replaces',
      );
    });

    test('still says something when the error is empty', () {
      expect(playbackErrorMessage('   '), isNotEmpty);
      expect(playbackErrorMessage(''), contains('unknown reason'));
    });
  });
}
