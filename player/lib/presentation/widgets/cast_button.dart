import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cast/cast_providers.dart';

/// How a cast affordance looks in a given [CastConnection].
///
/// Shared by [CastButton] and [CastChromeIcon] so the two cannot drift into
/// disagreeing about what a state means. `Icons.cast_connected` is the
/// platform's "this app owns that receiver" glyph, so it appears only when a
/// connection is genuinely live — a device that has merely been chosen gets
/// the hollow `Icons.cast` in the same blue.
(IconData, Color, String) _castVisuals(CastConnection connection, String name) {
  return switch (connection) {
    CastConnection.none => (Icons.cast, Colors.white, 'Cast to device'),
    CastConnection.connecting => (
        Icons.cast,
        Colors.blue,
        'Connecting to $name…',
      ),
    CastConnection.connectedIdle => (
        Icons.cast_connected,
        Colors.blue,
        'Connected to $name',
      ),
    CastConnection.casting => (
        Icons.cast_connected,
        Colors.blue,
        'Casting to $name',
      ),
    CastConnection.chosenOffline => (
        Icons.cast,
        Colors.blue,
        '$name — not connected',
      ),
  };
}

/// The cast affordance, shown in app bars and as the shell overlay.
///
/// Renders nothing when the current build has no cast capability at all
/// (e.g. web), so unsupported builds show no dead affordance.
class CastButton extends ConsumerWidget {
  final VoidCallback onPressed;

  const CastButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(castCapabilitiesProvider).any) {
      return const SizedBox.shrink();
    }

    final connection = ref.watch(castConnectionProvider);
    final device = ref.watch(castDisplayDeviceProvider);
    final (glyph, color, tooltip) =
        _castVisuals(connection, device?.name ?? 'device');

    return IconButton(
      key: const Key('cast-button'),
      icon: connection == CastConnection.connecting
          ? Stack(
              alignment: Alignment.center,
              children: [
                Icon(glyph, color: color, size: 16),
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.blue,
                  ),
                ),
              ],
            )
          : Icon(glyph, color: color),
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.5),
      ),
      tooltip: tooltip,
    );
  }
}

/// The cast glyph for the playback chrome's top bar.
///
/// [CastButton] cannot be reused there: it is a 48px `IconButton` carrying its
/// own opaque background, which neither fits `GlassPill`'s 36px height nor
/// wants a second surface behind the one the pill already draws. This renders
/// the glyph alone and lets the pill own the surface, the tap target and the
/// hover cursor — so it is deliberately *not* tappable itself.
///
/// Unlike [CastButton] this does not check capability, because `ChromeTopBar`
/// decides whether to draw the pill from whether its `castAction` is null: a
/// glyph that shrank itself to nothing would leave an empty glass pill
/// floating in the corner. Build it through [castChromeActionFor] instead.
class CastChromeIcon extends ConsumerWidget {
  const CastChromeIcon({super.key});

  static const Key iconKey = Key('cast-chrome-icon');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(castConnectionProvider);
    final device = ref.watch(castDisplayDeviceProvider);
    final (glyph, color, tooltip) =
        _castVisuals(connection, device?.name ?? 'device');

    // Idle inherits the pill's own IconTheme (white @ 0.80) so the cast glyph
    // matches the back chevron beside it; CastButton's opaque white would
    // read brighter than every other pill glyph. Every other state keeps the
    // shared blue, which is the entire point of the state being visible.
    final resolved = connection == CastConnection.none ? null : color;

    return Tooltip(
      message: tooltip,
      child: connection == CastConnection.connecting
          // Sized down from CastButton's 24px ring: this one has to sit
          // inside a 36px pill without forcing the top bar to grow.
          ? Stack(
              alignment: Alignment.center,
              children: [
                Icon(glyph, key: iconKey, color: resolved, size: 12),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.blue,
                  ),
                ),
              ],
            )
          : Icon(glyph, key: iconKey, color: resolved),
    );
  }
}

/// The chrome's cast affordance, or null when this build cannot cast at all.
///
/// The capability check lives here rather than inside [CastChromeIcon] so that
/// an incapable build omits the whole pill instead of drawing an empty one —
/// see [CastChromeIcon]'s dartdoc.
Widget? castChromeActionFor(WidgetRef ref) =>
    ref.watch(castCapabilitiesProvider).any ? const CastChromeIcon() : null;
