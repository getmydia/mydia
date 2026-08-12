import 'package:flutter/material.dart';

/// The affordance shown when a browser declines to start playback on its own.
///
/// Every browser refuses to start an unmuted video without a live user
/// activation, and a cold start cannot promise one: the tap that asked for
/// playback is separated from the `play()` call by a route change, several
/// round trips to the server and the media open itself. Over a remote server
/// that gap routinely outlasts the activation window, and the browser rejects
/// the play with a `NotAllowedError`.
///
/// Nothing has actually failed at that point. The media is open, the manifest
/// is attached and the first frames are buffered, so this covers the video it
/// is waiting on rather than replacing it, and the whole surface is the
/// target: on a phone, hunting for a glyph is a worse ask than tapping the
/// picture already under your thumb.
class TapToPlayOverlay extends StatelessWidget {
  /// Starts playback. Must call `play()` synchronously — the tap *is* the
  /// activation, and awaiting anything before spending it hands back exactly
  /// the failure this overlay exists to recover from.
  final VoidCallback onPlay;

  const TapToPlayOverlay({
    super.key,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Semantics(
        button: true,
        label: 'Play',
        child: GestureDetector(
          onTap: onPlay,
          // Without this the scrim's transparent regions would pass taps
          // through to the gesture controls underneath, so the half of the
          // screen that is not the glyph would seek instead of play.
          behavior: HitTestBehavior.opaque,
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.45),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    size: 56,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Tap to play',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'Your browser needs a tap before it will start the video.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white70,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
