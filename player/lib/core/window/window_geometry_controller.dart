import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'window_controller.dart';
import 'window_geometry.dart';
import 'window_geometry_math.dart';
import 'window_geometry_store.dart';

/// Supplies the current displays. Injected so tests need no plugin.
typedef WorkAreaReader = Future<List<WorkArea>> Function();

/// Restores the window's geometry at startup and keeps the store in step with
/// it afterwards.
///
/// Every method swallows its failures: this runs inside `_startApp`, which
/// documents an invariant that nothing after
/// `WidgetsFlutterBinding.ensureInitialized()` escapes uncaught.
class WindowGeometryController with WindowListener {
  final WindowController _window;
  final WindowGeometryStore _store;
  final WorkAreaReader _readWorkAreas;
  final Duration _debounce;
  Timer? _pending;
  bool _paused = false;

  /// Identifies whichever [pause] call is currently in effect. `null` when
  /// nothing has paused the controller.
  ///
  /// Without this, pause/resume is a plain boolean shared by every caller,
  /// so a stale `resume()` from one owner could un-pause a controller a
  /// *different* owner still holds -- e.g. a previous player session's
  /// `detach()` finishing after a new session's `attach()` already paused
  /// tracking again. Latent today (nothing remounts a `PlayerScreen` while
  /// another is still attached), but cheap enough to make structural rather
  /// than coincidental. See [pause] and [resume].
  Object? _owner;

  /// Bumped on every [pause]. `_save()` is asynchronous and can suspend on a
  /// platform-channel `await` for the entire body — checking `_paused` only
  /// at entry is not enough, because a save can resume *after* `pause()` has
  /// already run (e.g. the player just reshaped the window) and would then
  /// persist the player's geometry. Capturing the generation at the start of
  /// a save and re-checking it before every write catches that case, whereas
  /// a plain bool re-check would not distinguish "still the same pause" from
  /// "paused, resumed, and paused again" — do not simplify this back to a
  /// bool.
  int _pauseGeneration = 0;

  WindowGeometryController({
    required WindowController window,
    required WindowGeometryStore store,
    required WorkAreaReader readWorkAreas,
    Duration debounce = const Duration(milliseconds: 500),
  })  : _window = window,
        _store = store,
        _readWorkAreas = readWorkAreas,
        _debounce = debounce;

  Duration get debounce => _debounce;

  /// Whether tracking is currently suspended. Read-only; the sizer owns the
  /// transitions via [pause]/[resume].
  bool get isPaused => _paused;

  /// Applies the stored geometry, or a centered default on a first launch.
  Future<void> restore() async {
    try {
      await _window.setMinimumSize(kMinWindowSize);
    } catch (e) {
      debugPrint('[WindowGeometry] Failed to set minimum size: $e');
    }

    try {
      final areas = await _readWorkAreas();
      final stored = _store.get();

      final target = stored == null
          ? defaultWindowRect(areas)
          : recoverOffscreenWindow(stored.bounds, areas);

      // Null means we could not read any display. Leave the window wherever
      // the OS put it rather than guessing at coordinates.
      if (target == null) return;

      await _window.setBounds(target);
      if (stored?.maximized ?? false) await _window.maximize();
    } catch (e) {
      debugPrint('[WindowGeometry] Failed to restore window geometry: $e');
    }
  }

  /// Stops all reading and writing of window state.
  ///
  /// The player owns the window while it is mounted, and its aspect-driven
  /// resizes must never reach the store — otherwise a 2.39:1 letterbox window
  /// becomes the geometry the app relaunches into.
  ///
  /// Returns an opaque token identifying this pause. Pass it back to
  /// [resume] -- a controller only un-pauses for the owner that currently
  /// holds it.
  Object pause() {
    final owner = Object();
    _owner = owner;
    _paused = true;
    _pauseGeneration++;
    _pending?.cancel();
    _pending = null;
    return owner;
  }

  /// Resumes tracking, but only if [owner] is the token returned by the
  /// [pause] call currently in effect. A stale token -- one from a pause
  /// that a later [pause] has since superseded -- is a no-op instead of
  /// un-pausing a controller a different owner still holds.
  void resume(Object? owner) {
    if (owner != _owner) return;
    _paused = false;
  }

  void dispose() {
    _pending?.cancel();
    _pending = null;
  }

  // `onWindowResized`/`onWindowMoved` are documented `@platforms macos,windows`
  // and never fire on Linux, so we take the continuous variants and lean on
  // the debounce to make that affordable.
  @override
  void onWindowResize() => _schedule();

  @override
  void onWindowMove() => _schedule();

  @override
  void onWindowMaximize() => _schedule();

  @override
  void onWindowUnmaximize() => _schedule();

  @override
  void onWindowClose() => unawaited(flush());

  void _schedule() {
    if (_paused) return;
    _pending?.cancel();
    _pending = Timer(_debounce, () => unawaited(_save()));
  }

  /// Writes any pending change now. Best-effort: if the OS kills the process
  /// first we lose at most one debounce interval of dragging.
  Future<void> flush() async {
    if (_pending == null) return;
    _pending!.cancel();
    _pending = null;
    await _save();
  }

  Future<void> _save() async {
    if (_paused) return;
    final generation = _pauseGeneration;

    try {
      // Fullscreen bounds are the display. Neither worth storing nor safe to
      // restore into, and we deliberately never restore fullscreen.
      if (await _window.isFullScreen()) return;

      if (await _window.isMaximized()) {
        // getBounds() would return the maximized frame here. Record only the
        // flag so the user's real window size survives.
        final stored = _store.get();
        if (stored == null || !stored.maximized) {
          final geometry = (stored ??
                  WindowGeometry(
                      bounds: await _window.getBounds(), maximized: true))
              .copyWith(maximized: true);
          if (_paused || _pauseGeneration != generation) return;
          await _store.save(geometry);
        }
        return;
      }

      final geometry =
          WindowGeometry(bounds: await _window.getBounds(), maximized: false);
      if (_paused || _pauseGeneration != generation) return;
      await _store.save(geometry);
    } catch (e) {
      debugPrint('[WindowGeometry] Failed to save window geometry: $e');
    }
  }
}
