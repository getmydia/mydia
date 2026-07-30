import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/player/duration_override.dart';
import '../../../core/player/platform_features.dart';
import '../../../core/theme/depth_tokens.dart';
import 'center_play_button.dart';
import 'chrome_panel.dart';
import 'chrome_top_bar.dart';
import 'panel_controls.dart';
import 'transport_cluster.dart';
import 'video_progress_bar.dart';

/// Visibility and motion state machine for playback chrome.
///
/// Player-free so the timing rules can be tested directly. [PlaybackChrome]
/// wraps it.
///
/// Chrome hides only when all of these hold: playback is running, the user is
/// not scrubbing, and the pointer is not resting over the chrome. That last
/// condition fixes a real defect — previously the chrome would fade out from
/// under a stationary cursor that was aiming at a button.
class ChromeVisibility extends StatefulWidget {
  /// Whether playback is running. Chrome never auto-hides while paused.
  final bool isPlaying;

  /// Whether the user is scrubbing. Chrome never auto-hides mid-seek.
  final bool isSeeking;

  final Widget child;

  final Duration autoHide;

  final ValueChanged<bool>? onVisibilityChanged;

  const ChromeVisibility({
    super.key,
    required this.isPlaying,
    required this.child,
    this.isSeeking = false,
    this.autoHide = const Duration(seconds: 3),
    this.onVisibilityChanged,
  });

  static const Key contentKey = Key('chrome-content');

  @override
  State<ChromeVisibility> createState() => _ChromeVisibilityState();
}

/// `IgnorePointer` wraps `MouseRegion`, which wraps content, in [build] — not
/// the other way around, and not opaque. Two things ride on that exact
/// order:
///
/// - **Hidden case:** `MouseRegion` defaults `opaque: true`, self-registering
///   a hit across its whole geometry regardless of descendants — needed so
///   hover is detected over bare padding, not just over a specific control.
///   If it sat *outside* `IgnorePointer` it would keep doing that while
///   `ignoring` is true, making the enclosing `Stack` (topmost-child-first)
///   stop before ever falling through to the background tap-to-reveal
///   catcher — chrome could never be tapped back from hidden. Nesting it
///   *inside* `IgnorePointer` lets `ignoring: true` short-circuit first, so
///   hidden chrome always falls through. The cost — no onEnter/onExit while
///   hidden — is fine: nothing left to protect from auto-hiding, and
///   Flutter's mouse tracker re-hit-tests every connected device's position
///   on the next frame once `ignoring` flips back to false, so a cursor
///   already resting on the content is still picked up the instant chrome
///   reappears.
/// - **Visible case:** an opaque `MouseRegion` here has the *same* problem in
///   reverse — it would claim every hit inside `content` regardless of
///   descendants, permanently blocking the Stack's background
///   `onTap: _toggle` catcher for as long as chrome stayed *shown*. Concretely:
///   playing, chrome visible, tapping the video to dismiss it did nothing.
///   `hitTestBehavior: HitTestBehavior.deferToChild` below fixes that (a hit
///   with nothing underneath now correctly returns false) without weakening
///   the hidden case, which is governed by `IgnorePointer`, not this flag.
///   Residual nuance: hover over a *genuinely* empty region — no `Text`
///   (`RenderParagraph.hitTestSelf` is unconditionally true) and no
///   gesture-registering descendant nearby — no longer registers. Narrow in
///   practice: every pill carries `Text`, every control is an opaque
///   `ControlButton`, and the scrubber is a full-width opaque hit target;
///   only a few 4-8px inter-button spacers are truly bare.
class _ChromeVisibilityState extends State<ChromeVisibility>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// [_controller] run through the spec's asymmetric easing — `curveStandard`
  /// in, `curveEmphasized` out. Fed raw, `FadeTransition`/[ChromeSlide] would
  /// animate linearly, unlike every other timed widget in this plan.
  late final CurvedAnimation _curved;

  Timer? _hideTimer;

  /// Mutated directly, not via `setState` — safe because [build] never reads
  /// this itself, only [_mayHide] does. Route through `setState` if that
  /// changes.
  bool _pointerOverChrome = false;

  /// Authoritative shown/hidden intent. Deliberately **not** derived from
  /// `_controller.value > 0` (the brief's original approach): that value is
  /// only ever read when this State's `build()` reruns (on `setState`, never
  /// on a bare animation tick), so it froze stale — hidden chrome silently
  /// stayed interactive underneath the fade. It also stays truthy for nearly
  /// all of the 250ms hide fade, so a tap arriving mid-fade read as "still
  /// visible" and hid further instead of restoring. A plain field, flipped
  /// the instant [_show]/[_hide] runs, fixes both.
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      value: 1.0,
      duration: DepthTokens.motionFast, // show
      reverseDuration: DepthTokens.motionMedium, // hide
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: DepthTokens.curveStandard,
      reverseCurve: DepthTokens.curveEmphasized,
    );
    _restartTimer();
  }

  @override
  void didUpdateWidget(ChromeVisibility old) {
    super.didUpdateWidget(old);
    if (old.isPlaying != widget.isPlaying ||
        old.isSeeking != widget.isSeeking) {
      if (widget.isPlaying && !widget.isSeeking) {
        _restartTimer();
      } else {
        _hideTimer?.cancel();
        _show();
      }
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool get _mayHide =>
      widget.isPlaying && !widget.isSeeking && !_pointerOverChrome;

  void _restartTimer() {
    _hideTimer?.cancel();
    if (!_mayHide) return;
    _hideTimer = Timer(widget.autoHide, () {
      if (mounted && _mayHide) _hide();
    });
  }

  void _show() {
    if (!_visible) {
      setState(() => _visible = true);
      _notifyVisibility(true);
    }
    _controller.forward();
    _restartTimer();
  }

  void _hide() {
    _hideTimer?.cancel();
    if (_visible) {
      setState(() => _visible = false);
      _notifyVisibility(false);
    }
    _controller.reverse();
  }

  void _toggle() => _visible ? _hide() : _show();

  /// [_show]/[_hide] can run synchronously from [didUpdateWidget] (e.g.
  /// playback pausing while hidden), itself called during an ancestor's
  /// build/element-update phase — a consumer callback that calls `setState`
  /// in response (the obvious Task 13 implementation: cursor, system UI,
  /// wakelock) would throw "setState() called during build". Deferring
  /// unconditionally, not only on that path, means callers never need to
  /// know which call site triggered it.
  void _notifyVisibility(bool visible) {
    final callback = widget.onVisibilityChanged;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => callback(visible));
  }

  @override
  Widget build(BuildContext context) {
    final content = ChromeAnimation(
      animation: _curved,
      child: FadeTransition(
        opacity: _curved,
        // See the class dartdoc above for why IgnorePointer wraps
        // MouseRegion, and why that MouseRegion uses `hitTestBehavior:
        // deferToChild` instead of the default `opaque`.
        child: IgnorePointer(
          ignoring: !_visible,
          child: MouseRegion(
            hitTestBehavior: HitTestBehavior.deferToChild,
            onEnter: (_) {
              _pointerOverChrome = true;
              _hideTimer?.cancel();
            },
            onExit: (_) {
              _pointerOverChrome = false;
              _restartTimer();
            },
            child: KeyedSubtree(
              key: ChromeVisibility.contentKey,
              child: widget.child,
            ),
          ),
        ),
      ),
    );

    Widget stack = Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          child: const SizedBox.expand(),
        ),
        content,
      ],
    );

    if (!PlatformFeatures.isMobile) {
      stack = MouseRegion(
        // Cursor disappears with the chrome.
        cursor: _visible ? MouseCursor.defer : SystemMouseCursors.none,
        onHover: (_) {
          // Skip the redundant cancel-and-reschedule when nothing would
          // change — otherwise a moving mouse allocates a fresh `Timer` on
          // every hover event, up to ~120/sec.
          if (_visible && _hideTimer != null) return;
          _show();
        },
        child: stack,
      );
    }

    return stack;
  }
}

/// Exposes the chrome's show/hide animation to descendants so each slot can
/// apply its own entrance translate without [ChromeVisibility] needing to know
/// what it is wrapping.
class ChromeAnimation extends InheritedWidget {
  final Animation<double> animation;

  const ChromeAnimation({
    super.key,
    required this.animation,
    required super.child,
  });

  static Animation<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChromeAnimation>()?.animation;

  @override
  bool updateShouldNotify(ChromeAnimation oldWidget) =>
      oldWidget.animation != animation;
}

/// Translates its child by [hiddenOffsetY] when chrome is hidden, settling to
/// zero as it appears — so chrome reads as arriving rather than blinking.
///
/// Honours [MediaQuery.disableAnimationsOf] by skipping the translate; the
/// fade is kept, since removing it entirely would make chrome pop.
class ChromeSlide extends StatelessWidget {
  /// Vertical offset in logical pixels while hidden. Positive moves down.
  final double hiddenOffsetY;

  final Widget child;

  const ChromeSlide({
    super.key,
    required this.hiddenOffsetY,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final animation = ChromeAnimation.maybeOf(context);
    if (animation == null || MediaQuery.disableAnimationsOf(context)) {
      return child;
    }

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, (1.0 - animation.value) * hiddenOffsetY),
        child: child,
      ),
      child: child,
    );
  }
}

/// All playback chrome: the top pill row and the bottom control panel.
///
/// Replaces four independently-positioned floating elements — the top bar and
/// episode-navigation buttons in `player_screen.dart`, plus the floating
/// centre transport and glass bar in `custom_video_controls.dart` — with two
/// objects under a single visibility timer and animation.
///
/// **Forward note for Task 13:** [ChromeVisibility]'s background
/// tap-to-toggle catcher is a full-screen, opaque `GestureDetector`, painted
/// as this widget's topmost layer — it claims every tap chrome content
/// doesn't, including ones meant for anything stacked *below*
/// [PlaybackChrome], e.g. `gesture_controls.dart`'s double-tap ±10s (which
/// the `CenterPlayButton` comment below already relies on as the reason
/// mobile has no floating skip buttons). Compose the two so double-tap still
/// reaches `GestureControls`; not attempted here.
class PlaybackChrome extends StatefulWidget {
  final Player player;
  final String? title;
  final VoidCallback? onBack;
  final Widget? castAction;

  final VoidCallback? onAudioTap;
  final VoidCallback? onSubtitleTap;
  final VoidCallback? onQualityTap;
  final VoidCallback? onFullscreenTap;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;

  final bool isFullscreen;
  final int audioTrackCount;
  final int subtitleTrackCount;
  final String? selectedAudioLabel;
  final String? selectedSubtitleLabel;
  final String? selectedQualityLabel;

  final ValueChanged<bool>? onVisibilityChanged;

  const PlaybackChrome({
    super.key,
    required this.player,
    this.title,
    this.onBack,
    this.castAction,
    this.onAudioTap,
    this.onSubtitleTap,
    this.onQualityTap,
    this.onFullscreenTap,
    this.onPreviousEpisode,
    this.onNextEpisode,
    this.isFullscreen = false,
    this.audioTrackCount = 0,
    this.subtitleTrackCount = 0,
    this.selectedAudioLabel,
    this.selectedSubtitleLabel,
    this.selectedQualityLabel,
    this.onVisibilityChanged,
  });

  @override
  State<PlaybackChrome> createState() => _PlaybackChromeState();
}

class _PlaybackChromeState extends State<PlaybackChrome> {
  bool _seeking = false;

  void _seekBy(Duration delta) {
    final player = widget.player;
    final duration = DurationOverride.getDuration(player.state.duration);
    final target = player.state.position + delta;
    player.seek(
      target < Duration.zero
          ? Duration.zero
          : (target > duration ? duration : target),
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = PanelMetrics.forWidth(MediaQuery.sizeOf(context).width);

    return StreamBuilder<bool>(
      stream: widget.player.stream.playing,
      initialData: widget.player.state.playing,
      builder: (context, snapshot) {
        return ChromeVisibility(
          isPlaying: snapshot.data ?? false,
          isSeeking: _seeking,
          onVisibilityChanged: widget.onVisibilityChanged,
          child: SafeArea(
            child: Stack(
              children: [
                Positioned(
                  top: 16,
                  left: 16,
                  right: 16,
                  child: ChromeSlide(
                    hiddenOffsetY: -6,
                    child: ChromeTopBar(
                      title: widget.title,
                      onBack: widget.onBack,
                      castAction: widget.castAction,
                    ),
                  ),
                ),
                // Mobile only: a large centre play/pause. Desktop/web use the
                // panel's own transport; on touch a one-handed thumb reach to
                // a 48px in-bar button is worse than a centre target. No skip
                // buttons here — `gesture_controls.dart` already does
                // double-tap-left/right for ±10s.
                if (PlatformFeatures.isMobile)
                  Center(
                    child: CenterPlayButton(player: widget.player),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: metrics.bottomOffset,
                  child: ChromeSlide(
                    hiddenOffsetY: 8,
                    child: Center(
                      child: ChromePanel(
                        metrics: metrics,
                        transport: TransportCluster(
                          player: widget.player,
                          onBack10: () => _seekBy(const Duration(seconds: -10)),
                          onForward10: () =>
                              _seekBy(const Duration(seconds: 10)),
                          onPreviousEpisode: widget.onPreviousEpisode,
                          onNextEpisode: widget.onNextEpisode,
                        ),
                        // Unconditional per ChromePanel's `volume` dartdoc:
                        // it already gates visibility internally via
                        // Visibility(maintainState: true), so
                        // VolumeCluster's `_lastVolume` survives a
                        // breakpoint crossing only if it isn't also rebuilt
                        // from scratch here.
                        volume: VolumeCluster(player: widget.player),
                        secondary: SecondaryCluster(
                          onSubtitleTap: widget.onSubtitleTap,
                          onAudioTap: widget.onAudioTap,
                          onQualityTap: widget.onQualityTap,
                          onFullscreenTap: widget.onFullscreenTap,
                          audioTrackCount: widget.audioTrackCount,
                          subtitleTrackCount: widget.subtitleTrackCount,
                          selectedAudioLabel: widget.selectedAudioLabel,
                          selectedSubtitleLabel: widget.selectedSubtitleLabel,
                          selectedQualityLabel: widget.selectedQualityLabel,
                          isFullscreen: widget.isFullscreen,
                        ),
                        scrubber: _ScrubberRow(
                          player: widget.player,
                          touchTargets: metrics.touchTargets,
                          onSeekStart: () => setState(() => _seeking = true),
                          onSeekEnd: () => setState(() => _seeking = false),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Row 2 of the panel: elapsed, scrubber, remaining.
///
/// Timecodes flank the scrubber they describe. Previously they sat at opposite
/// ends of a full-width bar, up to ~1450px apart from each other and from the
/// track.
class _ScrubberRow extends StatelessWidget {
  final Player player;
  final bool touchTargets;
  final VoidCallback onSeekStart;
  final VoidCallback onSeekEnd;

  const _ScrubberRow({
    required this.player,
    required this.touchTargets,
    required this.onSeekStart,
    required this.onSeekEnd,
  });

  /// Both timecodes share this style — deliberately identical. The former
  /// `bottom_controls_bar.dart` styled elapsed at full white and remaining at
  /// `white @ 0.7`; that asymmetry measured as the single worst-case contrast
  /// on the whole panel (2.32:1) in Task 10's audit.
  ///
  /// The shadow is load-bearing, not decorative: `glass_legibility_test.dart`
  /// measures the fill alone at this row's height as 2.78:1 — under the WCAG
  /// SC 1.4.3 text floor of 4.5:1 — and 10.68:1 with this exact shadow
  /// composited in. Never apply this treatment to an icon; row 1's icons stay
  /// unshadowed, held to the looser 3:1 non-text floor instead (see
  /// `DepthTokens.playerChromeFillTopAlpha`'s doc comment).
  static const TextStyle _timeStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: Color(0x8CFFFFFF), // white @ 0.55
    fontFeatures: [FontFeature.tabularFigures()],
    shadows: [
      Shadow(color: Color(0x99000000), blurRadius: 4), // black @ 0.6, 4px
    ],
  );

  static String _format(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration>(
          stream: player.stream.duration,
          initialData: player.state.duration,
          builder: (context, durationSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final duration = DurationOverride.getDuration(
              durationSnapshot.data ?? Duration.zero,
            );
            final remaining = duration - position;

            return Row(
              children: [
                Text(_format(position), style: _timeStyle),
                const SizedBox(width: 12),
                Expanded(
                  child: VideoProgressBar(
                    player: player,
                    touchTarget: touchTargets,
                    onSeekStart: onSeekStart,
                    onSeekEnd: onSeekEnd,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '-${_format(remaining.isNegative ? Duration.zero : remaining)}',
                  style: _timeStyle,
                ),
              ],
            );
          },
        );
      },
    );
  }
}
