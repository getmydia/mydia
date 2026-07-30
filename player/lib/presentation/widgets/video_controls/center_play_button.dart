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
