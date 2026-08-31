import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// A small spinner shown over the retained video frame while the player is
/// buffering.
///
/// Deliberately not the full-screen loading overlay the screen shows on a cold
/// start. A seek in a full-playlist session keeps the last frame, the scrub bar
/// and the rest of the chrome on screen; all that is missing is an
/// acknowledgement that the player is fetching. Anything larger would recreate
/// the reload this change exists to remove.
class BufferingIndicator extends StatelessWidget {
  const BufferingIndicator({super.key, required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: player.stream.buffering,
      initialData: player.state.buffering,
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();

        return const Center(
          child: SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Colors.white,
            ),
          ),
        );
      },
    );
  }
}
