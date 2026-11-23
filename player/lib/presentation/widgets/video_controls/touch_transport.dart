import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/focus/focus_memory.dart';
import '../../../l10n/l10n.dart';
import '../controls/press_scale.dart';
import '../focus_highlight.dart';
import '../glass_surface.dart';
import 'control_button.dart';
import 'transport_cluster.dart';

/// The centre transport of the touch OSD: [previous] -10, play, +10 [next],
/// as large discs floating over the video.
///
/// Replaces the touch-only centre play button. It reuses the
/// [TransportSurface] keys, tooltips and focus-memory ids, so key lookups and
/// keyboard behaviour match every other tier. Seek and episode discs are
/// blur-free [GlassSurface.osdPill]s; the play disc is an opaque filled
/// circle with a drop shadow.
///
/// Episode buttons render only when [showEpisodeNav] is set and their callback
/// is non-null.
class TouchTransport extends StatelessWidget {
  final Player player;
  final VoidCallback onBack10;
  final VoidCallback onForward10;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;

  /// Whether the episode buttons may be shown at all.
  final bool showEpisodeNav;

  /// Optional externally-owned node for the play/pause button.
  final FocusNode? playPauseFocusNode;

  const TouchTransport({
    super.key,
    required this.player,
    required this.onBack10,
    required this.onForward10,
    this.onPreviousEpisode,
    this.onNextEpisode,
    this.showEpisodeNav = false,
    this.playPauseFocusNode,
  });

  /// Play/pause disc diameter.
  static const double playSize = 68;

  /// Diameter of the -10 and +10 discs.
  static const double seekSize = 48;

  /// Diameter of the previous and next episode discs.
  static const double episodeSize = 40;

  /// Gap between discs.
  static const double gap = 28;

  /// Fill of the play disc (white-ish at 0.95).
  static const Color playFill = Color(0xF2F0EFED);

  /// Glyph colour on the play disc.
  static const Color playGlyph = Color(0xFF0B0B0C);

  static const double _playIconSize = 36;

  Widget _disc({
    required Key key,
    required Object memoryId,
    required int index,
    required IconData icon,
    required double size,
    required double iconSize,
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    return FocusMemoryItem(
      id: memoryId,
      index: index,
      child: PressScale(
        child: GlassSurface.osdPill(
          borderRadius: BorderRadius.circular(size / 2),
          child: ControlButton(
            key: key,
            icon: icon,
            size: size,
            iconSize: iconSize,
            tooltip: tooltip,
            onTap: onTap,
          ),
        ),
      ),
    );
  }

  Widget _playPause(BuildContext context, bool isPlaying) {
    final label = isPlaying
        ? context.l10n.commonPause
        : context.l10n.commonPlay;
    void toggle() => isPlaying ? player.pause() : player.play();
    return FocusMemoryItem(
      id: TransportSurface.playPauseKey,
      index: 2,
      child: PressScale(
        child: Semantics(
          button: true,
          label: label,
          child: Tooltip(
            message: label,
            child: GestureDetector(
              key: TransportSurface.playPauseKey,
              behavior: HitTestBehavior.opaque,
              onTap: toggle,
              child: FocusHighlight(
                focusNode: playPauseFocusNode,
                onActivate: toggle,
                circular: true,
                child: Container(
                  width: playSize,
                  height: playSize,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: playFill,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x73000000),
                        blurRadius: 30,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: _playIconSize,
                    color: playGlyph,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final previous = showEpisodeNav ? onPreviousEpisode : null;
    final next = showEpisodeNav ? onNextEpisode : null;

    return StreamBuilder<bool>(
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data ?? false;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (previous != null) ...[
              _disc(
                key: TransportSurface.previousEpisodeKey,
                memoryId: TransportSurface.previousEpisodeKey,
                index: 0,
                icon: Icons.skip_previous_rounded,
                size: episodeSize,
                iconSize: 24,
                tooltip: l10n.videoPreviousEpisode,
                onTap: previous,
              ),
              const SizedBox(width: gap),
            ],
            _disc(
              key: TransportSurface.back10Key,
              memoryId: TransportSurface.back10Key,
              index: 1,
              icon: Icons.replay_10_rounded,
              size: seekSize,
              iconSize: 24,
              tooltip: l10n.videoRewind10,
              onTap: onBack10,
            ),
            const SizedBox(width: gap),
            _playPause(context, isPlaying),
            const SizedBox(width: gap),
            _disc(
              key: TransportSurface.forward10Key,
              memoryId: TransportSurface.forward10Key,
              index: 3,
              icon: Icons.forward_10_rounded,
              size: seekSize,
              iconSize: 24,
              tooltip: l10n.videoForward10,
              onTap: onForward10,
            ),
            if (next != null) ...[
              const SizedBox(width: gap),
              _disc(
                key: TransportSurface.nextEpisodeKey,
                memoryId: TransportSurface.nextEpisodeKey,
                index: 4,
                icon: Icons.skip_next_rounded,
                size: episodeSize,
                iconSize: 24,
                tooltip: l10n.videoNextEpisode,
                onTap: next,
              ),
            ],
          ],
        );
      },
    );
  }
}
