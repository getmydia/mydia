/// Stub bitmap subtitle position for web.
///
/// media_kit's web backend drives an `HTMLVideoElement`. There is no mpv and
/// no bitmap renderer to move; text tracks are lifted through
/// `SubtitleView`'s padding instead.
library;

import 'package:media_kit/media_kit.dart';

Future<void> applySubtitlePosition(Player player, double subPos) async {}
