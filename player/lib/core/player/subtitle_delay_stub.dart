/// Stub subtitle delay adjustment for web.
///
/// media_kit's web backend drives an `HTMLVideoElement`; there is no mpv
/// process and no `sub-delay` property to set. Web subtitle bodies always
/// come from the `SubtitleContent` query, which already bakes the stored
/// offset in, so there is nothing left to correct here.
library;

import 'package:media_kit/media_kit.dart';

Future<void> applySubtitleDelay(Player player, int delayMs) async {}
