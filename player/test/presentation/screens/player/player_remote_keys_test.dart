// On a remote, arrow keys have to mean two different things. With the OSD
// hidden there is nothing focusable on screen, so left and right are the only
// way to seek. With it visible, the same keys have to walk the transport
// controls instead, or the focus rings the OSD renders are unreachable.
//
// Up and down never touch volume on a television. That belongs to the remote
// and the receiver, and binding it means one press changes two volumes.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

void main() {
  group('PlayerScreen.resolveArrowIntent on a television', () {
    ArrowIntent intent(LogicalKeyboardKey key, {required bool chromeVisible}) =>
        PlayerScreen.resolveArrowIntent(
          key: key,
          directionalPrimary: true,
          chromeVisible: chromeVisible,
        );

    test('left seeks back while the OSD is hidden', () {
      expect(
        intent(LogicalKeyboardKey.arrowLeft, chromeVisible: false),
        ArrowIntent.seekBackward,
      );
    });

    test('right seeks forward while the OSD is hidden', () {
      expect(
        intent(LogicalKeyboardKey.arrowRight, chromeVisible: false),
        ArrowIntent.seekForward,
      );
    });

    test('up reveals the OSD rather than changing volume', () {
      expect(
        intent(LogicalKeyboardKey.arrowUp, chromeVisible: false),
        ArrowIntent.revealChrome,
      );
    });

    test('down reveals the OSD rather than changing volume', () {
      expect(
        intent(LogicalKeyboardKey.arrowDown, chromeVisible: false),
        ArrowIntent.revealChrome,
      );
    });

    test('every arrow defers to focus traversal once the OSD is visible', () {
      for (final key in [
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
      ]) {
        expect(
          intent(key, chromeVisible: true),
          ArrowIntent.traverse,
          reason: '$key must walk the controls, not seek past them',
        );
      }
    });
  });

  group('PlayerScreen.resolveArrowIntent on a keyboard', () {
    ArrowIntent intent(LogicalKeyboardKey key, {required bool chromeVisible}) =>
        PlayerScreen.resolveArrowIntent(
          key: key,
          directionalPrimary: false,
          chromeVisible: chromeVisible,
        );

    test('left still seeks back regardless of the OSD', () {
      expect(
        intent(LogicalKeyboardKey.arrowLeft, chromeVisible: true),
        ArrowIntent.seekBackward,
      );
    });

    test('up still changes volume, which desktop viewers rely on', () {
      expect(
        intent(LogicalKeyboardKey.arrowUp, chromeVisible: false),
        ArrowIntent.volumeUp,
      );
    });

    test('down still changes volume', () {
      expect(
        intent(LogicalKeyboardKey.arrowDown, chromeVisible: false),
        ArrowIntent.volumeDown,
      );
    });
  });
}
