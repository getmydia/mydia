import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// A large centred play/pause button.
///
/// Mobile only. On desktop and web the transport lives inside the control
/// panel; on touch a one-handed thumb reach to a 48px in-bar button is worse
/// than a centre target. Skip buttons are deliberately absent here because
/// `gesture_controls.dart` already implements double-tap-left/right for ±10s.
class CenterPlayButton extends StatelessWidget {
  /// The media_kit player instance.
  final Player player;

  /// The size of the button.
  final double size;

  /// The size of the icon.
  final double iconSize;

  const CenterPlayButton({
    super.key,
    required this.player,
    this.size = 72,
    this.iconSize = 56,
  });

  /// Shadow behind the glyph.
  ///
  /// Every other control's "no per-glyph shadow" rule (see
  /// `ControlButton`'s doc comment) assumes a glass panel sits behind it —
  /// this button is the one exception: it paints directly on live video,
  /// with no backing surface at all. Without a shadow, a bright frame (snow,
  /// sky, a white title card) washes a plain white glyph out to 1:1
  /// contrast, on the one control mobile relies on most. Held to WCAG SC
  /// 1.4.11 (non-text, 3:1) against a worst-case pure-white frame — see
  /// `glass_legibility_test.dart`'s `CenterPlayButton` case, which fails if
  /// this shadow is removed or weakened.
  static const Shadow glyphShadow = Shadow(
    color: Color(0x99000000), // black @ 0.6
    blurRadius: 8,
  );

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data ?? false;

        return SizedBox(
          width: size,
          height: size,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                if (isPlaying) {
                  player.pause();
                } else {
                  player.play();
                }
              },
              borderRadius: BorderRadius.circular(size / 2),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, animation) {
                    return ScaleTransition(
                      scale: animation,
                      child: FadeTransition(
                        opacity: animation,
                        child: child,
                      ),
                    );
                  },
                  child: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    key: ValueKey(isPlaying),
                    size: iconSize,
                    color: Colors.white,
                    shadows: const [glyphShadow],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
