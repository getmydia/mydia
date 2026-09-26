import 'package:media_kit/media_kit.dart';

/// Reshapes the desktop window to match the video being played.
///
/// While a sizer is attached it owns the window: it pauses
/// `WindowGeometryController` so aspect-driven resizes never reach the store.
abstract interface class PlayerWindowSizer {
  /// Takes ownership of the window and snapshots its current geometry.
  Future<void> attach();

  /// Watches [params] for the video's display dimensions.
  ///
  /// `PlayerScreen._initializePlayer` builds a fresh `Player` -- and this is
  /// called again with its stream -- on a source switch, a session restart,
  /// and a later episode advance that reuses this `PlayerScreen` (its
  /// `didUpdateWidget` re-enters `_initializePlayer`). Only the *first*
  /// advance out of a pushed player builds a whole new `PlayerScreen` (and a
  /// new sizer) instead: see `test/core/router/player_route_handoff_test.dart`.
  /// Any previous subscription is cancelled.
  void bindVideoParams(Stream<VideoParams> params);

  /// Restores the snapshot and hands the window back.
  Future<void> detach();
}

/// Used on web, on mobile, and whenever `initDesktopWindow` did not run.
class NoopPlayerWindowSizer implements PlayerWindowSizer {
  const NoopPlayerWindowSizer();

  @override
  Future<void> attach() async {}

  @override
  void bindVideoParams(Stream<VideoParams> params) {}

  @override
  Future<void> detach() async {}
}
