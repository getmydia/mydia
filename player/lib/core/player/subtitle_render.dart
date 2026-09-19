/// Who draws the active subtitle track: mpv, or media_kit's Flutter overlay.
///
/// media_kit builds its `Player` with `libass: false` unless told otherwise,
/// and that sets mpv's `sub-visibility=no` at start-up: mpv draws nothing,
/// and media_kit_video's `SubtitleView` draws `sub-text` over the video
/// instead. `sub-text` is text. A bitmap track (PGS, VobSub, DVB, XSUB) has
/// none, so with that default a bitmap track shows nothing at all, in
/// direct play as much as when streaming. Handing mpv the drawing while a
/// bitmap track is active, and taking it back for text, keeps Flutter's
/// renderer for text (and spares Android the font asset libass would need
/// there) without two renderers ever drawing the same track.
library;

import 'package:media_kit/media_kit.dart';

import '../../domain/models/subtitle_format.dart';
import 'subtitle_render_stub.dart'
    if (dart.library.io) 'subtitle_render_native.dart' as platform;

/// Whether mpv, rather than the Flutter overlay, should draw a track whose
/// codec mpv reports as [codec].
bool mpvDrawsSubtitle(String? codec) => isImageSubtitleFormat(codec);

/// Keeps mpv's `sub-visibility` in step with the active track's codec for
/// the life of [player]. Call once per `Player`, before `open`, so a
/// default track mpv picks while opening is seen too. A no-op on web.
Future<void> watchSubtitleRendering(Player player) =>
    platform.watchSubtitleRendering(player);
