import 'package:media_kit/media_kit.dart';

import 'fullscreen_mode.dart';

/// The platform half of fullscreen.
///
/// Implementations own writing state: they call the `onChange` handed to
/// [createFullscreenBackend] whenever the platform *reports* a transition,
/// which for three of the four live modes means a real platform event rather
/// than an assumption. `FullscreenController` never writes its own notifier.
///
/// [enter] and [exit] are synchronous by contract. `webkitEnterFullscreen`
/// requires live user activation and any `await` before the call spends it.
abstract class FullscreenBackend {
  /// Resolved once at construction. Stable for the life of the process.
  FullscreenMode get mode;

  /// Hands over the media_kit player once it exists, so a web backend can
  /// reach the underlying `HTMLVideoElement`. A no-op on native.
  void attach(Player player);

  void enter();

  void exit();

  void dispose();
}
