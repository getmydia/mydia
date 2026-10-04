import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/player_key_bindings.dart';

KeyDownEvent _down(LogicalKeyboardKey key) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

PlayerKeyContext _ctx({
  bool directionalPrimary = false,
  bool chromeVisible = false,
  bool chromeHasFocus = false,
  bool hasNext = false,
  bool hasPrevious = false,
  bool upNextShowing = false,
  bool fullscreenAvailable = true,
  bool isFullscreen = false,
  bool isDesktop = true,
  bool shiftPressed = false,
  double volume = 50,
}) =>
    PlayerKeyContext(
      directionalPrimary: directionalPrimary,
      chromeVisible: chromeVisible,
      chromeHasFocus: chromeHasFocus,
      hasNext: hasNext,
      hasPrevious: hasPrevious,
      upNextShowing: upNextShowing,
      fullscreenAvailable: fullscreenAvailable,
      isFullscreen: isFullscreen,
      isDesktop: isDesktop,
      shiftPressed: shiftPressed,
      volume: volume,
    );

void main() {
  group('resolvePlayerKey', () {
    test('ignores key up', () {
      const up = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.space,
        timeStamp: Duration.zero,
      );
      expect(resolvePlayerKey(up, _ctx()), isNull);
    });

    test('keyboard arrows seek and change volume', () {
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.arrowLeft), _ctx()),
        isA<KeySeekBy>()
            .having((c) => c.offset, 'offset', const Duration(seconds: -10)),
      );
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.arrowRight), _ctx()),
        isA<KeySeekBy>()
            .having((c) => c.offset, 'offset', const Duration(seconds: 10)),
      );
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.arrowUp), _ctx(volume: 95)),
        isA<KeySetVolume>().having((c) => c.volume, 'volume', 100.0),
      );
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.arrowDown), _ctx(volume: 5)),
        isA<KeySetVolume>().having((c) => c.volume, 'volume', 0.0),
      );
    });

    test('remote arrows with OSD hidden scrub or reveal', () {
      final ctx = _ctx(directionalPrimary: true);
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.arrowLeft), ctx),
          isA<KeyScrub>().having((c) => c.forward, 'forward', false));
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.arrowRight), ctx),
          isA<KeyScrub>().having((c) => c.forward, 'forward', true));
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.arrowUp), ctx),
          isA<KeyRevealChrome>());
    });

    test('remote arrows with OSD shown fall through to traversal', () {
      final ctx = _ctx(directionalPrimary: true, chromeVisible: true);
      expect(
          resolvePlayerKey(_down(LogicalKeyboardKey.arrowLeft), ctx), isNull);
    });

    test('space toggles play without revealing; media play/pause reveals', () {
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.space), _ctx()),
        isA<KeyTogglePlay>().having((c) => c.revealChrome, 'reveal', false),
      );
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.mediaPlayPause), _ctx()),
        isA<KeyTogglePlay>().having((c) => c.revealChrome, 'reveal', true),
      );
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.mediaPlay), _ctx()),
          isA<KeyPlay>());
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.mediaPause), _ctx()),
          isA<KeyPause>());
    });

    test('enter reveals only on the remote tier with focus outside chrome', () {
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.enter), _ctx()), isNull);
      expect(
        resolvePlayerKey(
            _down(LogicalKeyboardKey.select), _ctx(directionalPrimary: true)),
        isA<KeyRevealChrome>(),
      );
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.enter),
            _ctx(directionalPrimary: true, chromeHasFocus: true)),
        isNull,
      );
    });

    test('media skip keys carry 30 second offsets', () {
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.mediaFastForward), _ctx()),
        isA<KeyMediaSkip>()
            .having((c) => c.offset, 'offset', const Duration(seconds: 30)),
      );
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.mediaRewind), _ctx()),
        isA<KeyMediaSkip>()
            .having((c) => c.offset, 'offset', const Duration(seconds: -30)),
      );
    });

    test('track keys are ignored without a neighbouring episode', () {
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.mediaTrackNext), _ctx()),
          isNull);
      expect(
        resolvePlayerKey(
            _down(LogicalKeyboardKey.mediaTrackNext), _ctx(hasNext: true)),
        isA<KeyNextEpisode>(),
      );
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.mediaTrackPrevious),
            _ctx(hasPrevious: true)),
        isA<KeyPreviousEpisode>(),
      );
    });

    test('page keys always go to episode navigation', () {
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.pageUp), _ctx()),
          isA<KeyEpisodeNav>());
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.pageDown), _ctx()),
          isA<KeyEpisodeNav>());
    });

    test('f and f11 need an available fullscreen route', () {
      expect(
        resolvePlayerKey(
            _down(LogicalKeyboardKey.keyF), _ctx(fullscreenAvailable: false)),
        isNull,
      );
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.f11), _ctx()),
          isA<KeyToggleFullscreen>());
    });

    test('t toggles always-on-top on desktop only', () {
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.keyT), _ctx()),
          isA<KeyToggleAlwaysOnTop>());
      expect(
        resolvePlayerKey(
            _down(LogicalKeyboardKey.keyT), _ctx(isDesktop: false)),
        isNull,
      );
    });

    test('m mutes a playing volume and restores full from zero', () {
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.keyM), _ctx(volume: 40)),
        isA<KeySetVolume>().having((c) => c.volume, 'volume', 0.0),
      );
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.keyM), _ctx(volume: 0)),
        isA<KeySetVolume>().having((c) => c.volume, 'volume', 100.0),
      );
    });

    test('z nudges earlier, shift+z later', () {
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.keyZ), _ctx()),
        isA<KeyNudgeSubtitle>().having((c) => c.deltaMs, 'delta', -100),
      );
      expect(
        resolvePlayerKey(
            _down(LogicalKeyboardKey.keyZ), _ctx(shiftPressed: true)),
        isA<KeyNudgeSubtitle>().having((c) => c.deltaMs, 'delta', 100),
      );
    });

    test('escape cancels up-next first, then leaves fullscreen', () {
      expect(
        resolvePlayerKey(_down(LogicalKeyboardKey.escape),
            _ctx(upNextShowing: true, isFullscreen: true)),
        isA<KeyCancelUpNext>(),
      );
      expect(
        resolvePlayerKey(
            _down(LogicalKeyboardKey.escape), _ctx(isFullscreen: true)),
        isA<KeyExitFullscreen>(),
      );
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.escape), _ctx()),
          isA<KeyConsumed>());
    });

    test('unbound keys are ignored', () {
      expect(resolvePlayerKey(_down(LogicalKeyboardKey.keyQ), _ctx()), isNull);
    });
  });
}
