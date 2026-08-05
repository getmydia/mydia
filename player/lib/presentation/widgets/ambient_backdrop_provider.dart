import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'ambient_backdrop_provider.g.dart';

/// The artwork source the shell-level [AmbientBackdrop] should render.
///
/// A null [imageUrl] means "no per-title artwork" — the backdrop shows its calm
/// static fallback (grids, settings). [id] is the stable identity used to key
/// the crossfade so equal sources don't re-trigger a transition.
@immutable
class BackdropSource {
  final String? imageUrl;
  final String? id;

  const BackdropSource({this.imageUrl, this.id});

  /// The static-fallback source (no artwork).
  static const BackdropSource none = BackdropSource();

  @override
  bool operator ==(Object other) =>
      other is BackdropSource && other.imageUrl == imageUrl && other.id == id;

  @override
  int get hashCode => Object.hash(imageUrl, id);
}

/// Carries the current shell backdrop source as two layers:
///
/// * a screen **default** — the focal pick for focal-item screens (home hero)
///   or [BackdropSource.none] for grids/settings, published from `build`; and
/// * a transient hover **override** — the artwork of the poster the user is
///   currently hovering on a browse/grid screen (R5/R9).
///
/// The effective state is `hover ?? default`, so hovering a poster shifts the
/// backdrop (and the real-blur chrome tints with it), and moving off reverts to
/// the screen default with no screen-side coordination. The [AmbientBackdrop]
/// in the shell watches the effective state and crossfades when it changes.
@riverpod
class AmbientBackdropController extends _$AmbientBackdropController {
  BackdropSource _default = BackdropSource.none;
  BackdropSource? _hover;

  @override
  BackdropSource build() => BackdropSource.none;

  /// The screen's default (fallback) source, ignoring any active hover
  /// override. Lets [publishBackdropSource] guard against the real default
  /// rather than the effective state.
  BackdropSource get defaultSource => _default;

  BackdropSource get _effective => _hover ?? _default;

  void _apply() {
    final next = _effective;
    if (state != next) {
      state = next;
    }
  }

  /// Sets the screen's default (fallback) source. Equivalent to the legacy
  /// [set]; used by [publishBackdropSource].
  void setDefault(BackdropSource source) {
    _default = source;
    _apply();
  }

  /// Sets the screen's default source. No-op when unchanged so we don't
  /// retrigger the crossfade on every rebuild.
  void set(BackdropSource source) => setDefault(source);

  /// Sets the transient hover override (the hovered poster's artwork), which
  /// takes precedence over the screen default until [clearHover].
  void setHover(BackdropSource source) {
    _hover = source;
    _apply();
  }

  /// Clears the hover override, reverting to the screen default.
  void clearHover() {
    if (_hover == null) return;
    _hover = null;
    _apply();
  }

  /// Clears the hover override only if it is still [source].
  ///
  /// A poster unmounting while hovered defers its clear to a post-frame
  /// callback, by which time a different poster may already have published
  /// its own override — during a scroll under a stationary cursor, for
  /// example. Clearing unconditionally would wipe that fresh override and
  /// leave the backdrop on the default while a poster is visibly hovered.
  void clearHoverIf(BackdropSource source) {
    if (_hover != source) return;
    clearHover();
  }

  /// Clears the default to the static fallback.
  void clear() => setDefault(BackdropSource.none);
}

/// Publishes [source] as the screen's default shell backdrop after the current
/// frame.
///
/// Browse screens call this from `build` so they don't mutate provider state
/// synchronously while building (which Riverpod disallows). Grid/settings
/// screens pass [BackdropSource.none] to show the calm static fallback. A
/// hover override (see [publishBackdropHover]) takes precedence over this.
void publishBackdropSource(WidgetRef ref, BackdropSource source) {
  // Skip scheduling when the stored default already equals this source, so
  // screens that rebuild on scroll/animation don't enqueue redundant post-frame
  // callbacks. Guarding against the *default* (not the effective state) means a
  // hovered poster whose artwork happens to equal `source` no longer blocks the
  // underlying default from being updated — otherwise clearHover() could revert
  // to a stale default.
  if (ref.read(ambientBackdropControllerProvider.notifier).defaultSource ==
      source) {
    return;
  }

  SchedulerBinding.instance.addPostFrameCallback((_) {
    // The ref may have been disposed if the screen left the tree before the
    // post-frame callback ran; guard against that.
    if (!ref.context.mounted) return;
    ref.read(ambientBackdropControllerProvider.notifier).setDefault(source);
  });
}

/// Sets the hovered poster's artwork as the backdrop override (R5/R9). Called
/// synchronously from a hover-enter callback (not during build), so no
/// post-frame deferral is needed. The controller no-ops on an unchanged
/// effective source, so re-hovering the same artwork won't retrigger a fade.
void publishBackdropHover(WidgetRef ref, BackdropSource source) {
  ref.read(ambientBackdropControllerProvider.notifier).setHover(source);
}

/// Clears the hover override, reverting the backdrop to the screen default.
void clearBackdropHover(WidgetRef ref) {
  ref.read(ambientBackdropControllerProvider.notifier).clearHover();
}

/// Clears the hover override only if it still equals [source] — see
/// [AmbientBackdropController.clearHoverIf].
void clearBackdropHoverIf(WidgetRef ref, BackdropSource source) {
  ref.read(ambientBackdropControllerProvider.notifier).clearHoverIf(source);
}
