// The player's input wiring was gated so that a television got the worst of
// both worlds: `InputCapabilities.touchPrimary` was true (because Android TV
// reports isNativeMobile), so tap and double-tap gestures were installed for
// a viewer holding a remote, while `supportsKeyboardShortcuts` was false
// (desktop and web only), so the arrow-key handler was not. These predicates
// are what fix that, and they are pure so they can be checked for every
// platform combination from a single non-web host.

import 'dart:ui' show Size;

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
          isTablet: false,
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
          isTablet: false,
        ),
        isFalse,
      );
    });

    test('false on desktop', () {
      expect(
        PlayerScreen.wantsForcedLandscape(
          isMobile: false,
          directionalPrimary: false,
          isTablet: false,
        ),
        isFalse,
      );
    });
  });

  group('PlayerScreen.wantsForcedLandscape on a tablet', () {
    test('false: a tablet follows the device, as Infuse and Plex do', () {
      expect(
        PlayerScreen.wantsForcedLandscape(
          isMobile: true,
          directionalPrimary: false,
          isTablet: true,
        ),
        isFalse,
      );
    });
  });

  group('PlayerScreen.wantsImmersivePresentation', () {
    test('true on a phone or tablet', () {
      expect(
        PlayerScreen.wantsImmersivePresentation(
          isMobile: true,
          directionalPrimary: false,
        ),
        isTrue,
      );
    });

    test('false on a television, which has no system bars to hide', () {
      expect(
        PlayerScreen.wantsImmersivePresentation(
          isMobile: true,
          directionalPrimary: true,
        ),
        isFalse,
      );
    });

    test('false on desktop and web', () {
      expect(
        PlayerScreen.wantsImmersivePresentation(
          isMobile: false,
          directionalPrimary: false,
        ),
        isFalse,
      );
    });
  });

  group('PlayerScreen.isTabletSized', () {
    test('599 on the short side is a phone, in either orientation', () {
      expect(
        PlayerScreen.isTabletSized(logicalScreenSize: const Size(599, 900)),
        isFalse,
      );
      expect(
        PlayerScreen.isTabletSized(logicalScreenSize: const Size(900, 599)),
        isFalse,
      );
    });

    test('600 on the short side is a tablet, in either orientation', () {
      expect(
        PlayerScreen.isTabletSized(logicalScreenSize: const Size(600, 960)),
        isTrue,
      );
      expect(
        PlayerScreen.isTabletSized(logicalScreenSize: const Size(960, 600)),
        isTrue,
      );
    });
  });
}
