import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult, VoidCallback;

/// What an arrow key press means in the player.
///
/// A remote's D-pad and a keyboard's arrows deliver the same key codes, so one
/// handler serves both, but they cannot mean the same thing. A keyboard viewer
/// has a pointer and a volume slider; a remote viewer has neither, and the
/// only focusable things on screen are the OSD controls, which are not there
/// while the OSD is hidden.
enum ArrowIntent {
  seekBackward,
  seekForward,

  /// Start or continue a D-pad scrub: the directional-tier answer for left
  /// and right with the OSD hidden. A remote has no pointer to drag the bar
  /// with, so the press reveals the OSD and moves a cursor instead of seeking.
  scrubBackward,
  scrubForward,
  volumeUp,
  volumeDown,

  /// Show the OSD. The directional-tier answer for up and down, which have no
  /// volume to change: on a television that belongs to the remote and the
  /// receiver, and binding it means one press changes two volumes.
  revealChrome,

  /// Let the key fall through to focus traversal, so it walks the OSD's
  /// controls. Returning this means the handler must report `ignored`.
  traverse,
}

/// What a Back press does in the player.
///
/// On a remote, Back is the only way out of anything, so it peels one layer
/// at a time. Everywhere else it leaves the player.
enum BackAction { cancelScrub, hideChrome, pop }

/// Resolves an arrow key to its meaning for this input tier and OSD state.
///
/// Pure, for the same reason
/// `PlatformFeatures.computeSupportsKeyboardShortcuts` is: the tier is a
/// runtime platform answer that a single test host cannot vary.
ArrowIntent arrowIntentFor({
  required LogicalKeyboardKey key,
  required bool directionalPrimary,
  required bool chromeVisible,
}) {
  if (directionalPrimary && chromeVisible) return ArrowIntent.traverse;

  switch (key) {
    case LogicalKeyboardKey.arrowLeft:
      return directionalPrimary
          ? ArrowIntent.scrubBackward
          : ArrowIntent.seekBackward;
    case LogicalKeyboardKey.arrowRight:
      return directionalPrimary
          ? ArrowIntent.scrubForward
          : ArrowIntent.seekForward;
    case LogicalKeyboardKey.arrowUp:
      return directionalPrimary
          ? ArrowIntent.revealChrome
          : ArrowIntent.volumeUp;
    case LogicalKeyboardKey.arrowDown:
      return directionalPrimary
          ? ArrowIntent.revealChrome
          : ArrowIntent.volumeDown;
    default:
      return ArrowIntent.traverse;
  }
}

/// Resolves a Back press for this input tier and state.
///
/// Pure, like [arrowIntentFor]. Cancelling a
/// scrub comes before hiding the OSD: the viewer is looking at the cursor,
/// and Back meaning "never mind" is what every television player does.
BackAction backActionFor({
  required bool directionalPrimary,
  required bool scrubActive,
  required bool chromeBlocksBack,
}) {
  if (!directionalPrimary) return BackAction.pop;
  if (scrubActive) return BackAction.cancelScrub;
  if (chromeBlocksBack) return BackAction.hideChrome;
  return BackAction.pop;
}

/// Everything [resolvePlayerKey] reads about the screen at the moment of a
/// key press. Plain values, so the decision is testable without a widget.
class PlayerKeyContext {
  const PlayerKeyContext({
    required this.directionalPrimary,
    required this.chromeVisible,
    required this.chromeHasFocus,
    required this.hasNext,
    required this.hasPrevious,
    required this.upNextShowing,
    required this.fullscreenAvailable,
    required this.isFullscreen,
    required this.isDesktop,
    required this.shiftPressed,
    required this.volume,
  });

  final bool directionalPrimary;
  final bool chromeVisible;
  final bool chromeHasFocus;
  final bool hasNext;
  final bool hasPrevious;
  final bool upNextShowing;
  final bool fullscreenAvailable;
  final bool isFullscreen;
  final bool isDesktop;
  final bool shiftPressed;

  /// The player's volume, 0-100.
  final double volume;
}

/// What a key press asks the player screen to do. The screen executes it.
sealed class PlayerKeyCommand {
  const PlayerKeyCommand();
}

/// The arrow keys' plain skip, clamped to a known runtime.
final class KeySeekBy extends PlayerKeyCommand {
  const KeySeekBy(this.offset);
  final Duration offset;
}

/// Start or continue a D-pad scrub; falls back to a 10s skip when the
/// runtime is unknown.
final class KeyScrub extends PlayerKeyCommand {
  const KeyScrub({required this.forward});
  final bool forward;
}

final class KeySetVolume extends PlayerKeyCommand {
  const KeySetVolume(this.volume);
  final double volume;
}

/// Show the OSD and land focus on play/pause.
final class KeyRevealChrome extends PlayerKeyCommand {
  const KeyRevealChrome();
}

final class KeyTogglePlay extends PlayerKeyCommand {
  const KeyTogglePlay({this.revealChrome = false});
  final bool revealChrome;
}

final class KeyPlay extends PlayerKeyCommand {
  const KeyPlay();
}

final class KeyPause extends PlayerKeyCommand {
  const KeyPause();
}

/// A remote's fast-forward or rewind: a 30s seek, then the OSD.
final class KeyMediaSkip extends PlayerKeyCommand {
  const KeyMediaSkip(this.offset);
  final Duration offset;
}

final class KeyNextEpisode extends PlayerKeyCommand {
  const KeyNextEpisode();
}

final class KeyPreviousEpisode extends PlayerKeyCommand {
  const KeyPreviousEpisode();
}

/// PageUp/PageDown, handed to [handleEpisodeNavKey].
final class KeyEpisodeNav extends PlayerKeyCommand {
  const KeyEpisodeNav();
}

final class KeyToggleFullscreen extends PlayerKeyCommand {
  const KeyToggleFullscreen();
}

final class KeyExitFullscreen extends PlayerKeyCommand {
  const KeyExitFullscreen();
}

final class KeyToggleAlwaysOnTop extends PlayerKeyCommand {
  const KeyToggleAlwaysOnTop();
}

/// mpv's own subtitle-delay binding: z earlier, shift+z later.
final class KeyNudgeSubtitle extends PlayerKeyCommand {
  const KeyNudgeSubtitle(this.deltaMs);
  final int deltaMs;
}

final class KeyCancelUpNext extends PlayerKeyCommand {
  const KeyCancelUpNext();
}

/// Handled, with nothing to do.
final class KeyConsumed extends PlayerKeyCommand {
  const KeyConsumed();
}

/// What [event] means for the player, or null when the key is not the
/// player's to handle and must report `KeyEventResult.ignored`.
PlayerKeyCommand? resolvePlayerKey(KeyEvent event, PlayerKeyContext context) {
  if (event is! KeyDownEvent) return null;

  // Arrow keys mean different things depending on the input tier and
  // whether the OSD is on screen. See `arrowIntentFor`'s own dartdoc.
  final arrow = arrowIntentFor(
    key: event.logicalKey,
    directionalPrimary: context.directionalPrimary,
    chromeVisible: context.chromeVisible,
  );

  switch (arrow) {
    case ArrowIntent.seekBackward:
      return const KeySeekBy(Duration(seconds: -10));
    case ArrowIntent.seekForward:
      return const KeySeekBy(Duration(seconds: 10));
    case ArrowIntent.scrubBackward:
      return const KeyScrub(forward: false);
    case ArrowIntent.scrubForward:
      return const KeyScrub(forward: true);
    case ArrowIntent.volumeUp:
      return KeySetVolume((context.volume + 10.0).clamp(0.0, 100.0));
    case ArrowIntent.volumeDown:
      return KeySetVolume((context.volume - 10.0).clamp(0.0, 100.0));
    case ArrowIntent.revealChrome:
      return const KeyRevealChrome();
    case ArrowIntent.traverse:
      // Falls through to the switch below, which handles the non-arrow
      // keys. An arrow reaching here is deliberately left unhandled so
      // focus traversal moves between the OSD's controls.
      break;
  }

  switch (event.logicalKey) {
    case LogicalKeyboardKey.space:
      return const KeyTogglePlay();

    // A remote's centre press. With the OSD hidden there is no focused
    // control to receive it — the controls' own FocusHighlight is what
    // handles select/enter normally — so OK would otherwise do nothing at
    // all. Revealing and focusing is the same move the arrow keys make.
    //
    // Gated on the directional tier because the key handler also runs on
    // desktop and web (`wantsKeyHandling` is true there via
    // `supportsKeyboardShortcuts`), where Enter previously fell through to
    // `ignored` and did nothing. A keyboard user pressing Enter over a
    // hidden OSD has not asked for the OSD.
    case LogicalKeyboardKey.select:
    case LogicalKeyboardKey.enter:
    case LogicalKeyboardKey.gameButtonA:
      if (!context.directionalPrimary) return null;
      if (context.chromeHasFocus) return null;
      return const KeyRevealChrome();

    // A remote's transport buttons. The Chromecast remote's play/pause is
    // the one that matters here; the rest arrive from fuller remotes and
    // from desktop keyboards with a media row, which get them for free.
    case LogicalKeyboardKey.mediaPlayPause:
      return const KeyTogglePlay(revealChrome: true);
    case LogicalKeyboardKey.mediaPlay:
      return const KeyPlay();
    case LogicalKeyboardKey.mediaPause:
      return const KeyPause();
    case LogicalKeyboardKey.mediaFastForward:
      return const KeyMediaSkip(Duration(seconds: 30));
    case LogicalKeyboardKey.mediaRewind:
      return const KeyMediaSkip(Duration(seconds: -30));

    case LogicalKeyboardKey.mediaTrackNext:
      return context.hasNext ? const KeyNextEpisode() : null;
    case LogicalKeyboardKey.mediaTrackPrevious:
      return context.hasPrevious ? const KeyPreviousEpisode() : null;

    case LogicalKeyboardKey.keyF:
    case LogicalKeyboardKey.f11:
      // Gated on the same signal as the button, so the two cannot disagree
      // about whether fullscreen exists. Claiming the key while doing nothing
      // would swallow it from anything else that wants it.
      return context.fullscreenAvailable ? const KeyToggleFullscreen() : null;

    case LogicalKeyboardKey.keyT:
      return context.isDesktop ? const KeyToggleAlwaysOnTop() : null;

    case LogicalKeyboardKey.keyM:
      // Toggle mute
      return KeySetVolume(context.volume > 0 ? 0.0 : 100.0);

    case LogicalKeyboardKey.keyZ:
      // mpv's own subtitle-delay binding: z earlier, shift+z later. A
      // no-op with no track selected or the offsets query never having
      // succeeded -- see `_nudgeSubtitleDelay`.
      return KeyNudgeSubtitle(context.shiftPressed ? 100 : -100);

    case LogicalKeyboardKey.escape:
      // The prompt takes the first branch: while it is up, Escape means
      // "not this", not "leave fullscreen". This case already returned
      // `handled` unconditionally, so nothing downstream changes.
      if (context.upNextShowing) return const KeyCancelUpNext();
      if (context.isFullscreen) return const KeyExitFullscreen();
      return const KeyConsumed();

    // Previous/next episode. This is the only reachable path to episode
    // navigation on a narrow window: below `PanelMetrics.touchTargets`'s
    // breakpoint, `ChromePanel`'s in-bar transport drops to play/pause
    // only (see `TransportSurface.compact`), and that gate is on viewport
    // *width*, not `PlatformFeatures.isMobile` — so a narrowed desktop or
    // web browser window loses the in-bar buttons too, with no
    // `UpNextOverlay` (autoplay-only, next-episode-only) or touch gesture
    // to fall back on. This actually covers web now that
    // `PlatformFeatures.supportsKeyboardShortcuts` includes it (see that
    // getter's own dartdoc) — previously this whole `Focus`/`onKeyEvent`
    // wrapper was desktop-only, so a narrowed *web* window had no
    // fallback at all, keyboard or otherwise.
    case LogicalKeyboardKey.pageUp:
    case LogicalKeyboardKey.pageDown:
      return const KeyEpisodeNav();

    default:
      return null;
  }
}

/// Pure `PageUp`/`PageDown` episode-navigation key handling, split out of the
/// screen's key handler so it can be unit-tested directly.
///
/// Kept separate from [resolvePlayerKey] because PageUp/PageDown report
/// `handled` even with no episode to go to, which is the one key result the
/// screen cannot derive from a command alone. It only needs two booleans and
/// two callbacks, so it takes those as parameters instead of closing over
/// `State` fields, making it directly testable with a synthetic [KeyEvent]
/// and no widget tree at all.
///
/// Mirrors exactly what the in-bar previous/next-episode buttons do
/// (`TransportSurface`'s `onPreviousEpisode`/`onNextEpisode`, gated the same
/// way by [hasPreviousEpisode]/[hasNextEpisode]) — this key handler is a
/// fallback for when those buttons aren't reachable (see the call site's own
/// comment), not a separate, independently-gated feature.
KeyEventResult handleEpisodeNavKey(
  KeyEvent event, {
  required bool hasPreviousEpisode,
  required bool hasNextEpisode,
  required VoidCallback onPreviousEpisode,
  required VoidCallback onNextEpisode,
}) {
  if (event is! KeyDownEvent) {
    return KeyEventResult.ignored;
  }

  switch (event.logicalKey) {
    case LogicalKeyboardKey.pageUp:
      if (hasPreviousEpisode) {
        onPreviousEpisode();
      }
      return KeyEventResult.handled;

    case LogicalKeyboardKey.pageDown:
      if (hasNextEpisode) {
        onNextEpisode();
      }
      return KeyEventResult.handled;

    default:
      return KeyEventResult.ignored;
  }
}
