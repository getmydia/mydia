import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cast/cast_providers.dart';
import '../cast_visuals.dart';

/// The cast glyph for the playback chrome's top bar.
///
/// Lives under `video_controls/` rather than beside `CastButton` so the
/// icon-family guard (`icon_family_test.dart`) covers it: this glyph sits in
/// the same pill row as `Icons.chevron_left_rounded`, and a bare-family cast
/// icon next to a rounded chevron is exactly the mixed-fill drift that test
/// exists to catch.
///
/// `CastButton` cannot be reused here: it is a 48px `IconButton` carrying its
/// own opaque background, which neither fits `GlassPill`'s 36px height nor
/// wants a second surface behind the one the pill already draws. This renders
/// the glyph alone and lets the pill own the surface, the tap target and the
/// hover cursor — so it is deliberately *not* tappable itself.
///
/// Unlike `CastButton` this does not check capability, because `ChromeTopBar`
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
    final visuals = castVisualsFor(connection, device?.name ?? 'device');
    final glyph =
        visuals.connected ? Icons.cast_connected_rounded : Icons.cast_rounded;

    // Idle inherits the pill's own IconTheme (white @ 0.80) so the cast glyph
    // matches the back chevron beside it; CastButton's opaque white would
    // read brighter than every other pill glyph. Every other state keeps the
    // shared blue, which is the entire point of the state being visible.
    final color = connection == CastConnection.none ? null : visuals.color;

    return Tooltip(
      message: visuals.tooltip,
      child: connection == CastConnection.connecting
          // Sized down from CastButton's 24px ring: this one has to sit
          // inside a 36px pill without forcing the top bar to grow.
          ? Stack(
              alignment: Alignment.center,
              children: [
                Icon(glyph, key: iconKey, color: color, size: 12),
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
          : Icon(glyph, key: iconKey, color: color),
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
