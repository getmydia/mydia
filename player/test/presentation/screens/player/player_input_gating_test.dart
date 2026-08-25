// The player's input wiring was gated so that a television got the worst of
// both worlds: `InputCapabilities.touchPrimary` was true (because Android TV
// reports isNativeMobile), so tap and double-tap gestures were installed for
// a viewer holding a remote, while `supportsKeyboardShortcuts` was false
// (desktop and web only), so the arrow-key handler was not. These predicates
// are what fix that, and they are pure so they can be checked for every
// platform combination from a single non-web host.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

void main() {
  group('PlayerScreen.wantsKeyHandling', () {
    test('true on desktop, unchanged', () {
      expect(
        PlayerScreen.wantsKeyHandling(
          supportsKeyboardShortcuts: true,
          directionalPrimary: false,
        ),
        isTrue,
      );
    });

    test('true on a television, which had no key handler at all before', () {
      expect(
        PlayerScreen.wantsKeyHandling(
          supportsKeyboardShortcuts: false,
          directionalPrimary: true,
        ),
        isTrue,
      );
    });

    test('false on a phone, which drives playback with gestures', () {
      expect(
        PlayerScreen.wantsKeyHandling(
          supportsKeyboardShortcuts: false,
          directionalPrimary: false,
        ),
        isFalse,
      );
    });
  });

  group('PlayerScreen.wantsForcedLandscape', () {
    test('true on a phone, unchanged', () {
      expect(
        PlayerScreen.wantsForcedLandscape(
          isMobile: true,
          directionalPrimary: false,
        ),
        isTrue,
      );
    });

    test(
        'false on a television: it is already landscape and has no rotation '
        'to pin, and pinning it logs a platform error on some Google TV '
        'builds', () {
      expect(
        PlayerScreen.wantsForcedLandscape(
          isMobile: true,
          directionalPrimary: true,
        ),
        isFalse,
      );
    });

    test('false on desktop', () {
      expect(
        PlayerScreen.wantsForcedLandscape(
          isMobile: false,
          directionalPrimary: false,
        ),
        isFalse,
      );
    });
  });
}
