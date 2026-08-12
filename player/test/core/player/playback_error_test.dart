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

  group('autoplayBlocked', () {
    // The exact strings each engine rejects `HTMLVideoElement.play()` with.
    // They are transcribed rather than paraphrased on purpose: this function
    // has nothing but the wording to go on, so a test that reworded them
    // would stop defending anything.
    test('recognises WebKit, which is what iOS Safari reports', () {
      expect(
        autoplayBlocked(
          'The request is not allowed by the user agent or the platform in '
          'the current context, possibly because the user denied permission.',
        ),
        isTrue,
      );
    });

    test('recognises Firefox, which words it slightly differently', () {
      expect(
        autoplayBlocked(
          'The play method is not allowed by the user agent or the platform '
          'in the current context, possibly because the user denied '
          'permission.',
        ),
        isTrue,
      );
    });

    test('recognises Chromium, help URL and all', () {
      expect(
        autoplayBlocked(
          "play() failed because the user didn't interact with the document "
          'first. https://goo.gl/xX8pDD',
        ),
        isTrue,
      );
    });

    test('survives Chromium changing its help URL or its apostrophe', () {
      expect(
        autoplayBlocked(
          'play() failed because the user did not interact with the document '
          'first.',
        ),
        isTrue,
      );
    });

    test('leaves genuine load failures to the error screen', () {
      expect(
        autoplayBlocked(
          'Failed to open http://127.0.0.1:12345/direct/file-old/stream.',
        ),
        isFalse,
        reason: 'a dead source is fatal — offering a play button for it would '
            'strand the viewer tapping at a stream that will never start',
      );
      expect(autoplayBlocked('Audio device init failed'), isFalse);
      expect(autoplayBlocked(''), isFalse);
    });
  });
}
