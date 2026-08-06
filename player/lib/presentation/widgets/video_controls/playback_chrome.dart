import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/player/platform_features.dart';
import '../../../core/player/stream_timeline.dart';
import '../../../core/window/desktop_window.dart';
import '../../../core/window/traffic_lights.dart';
import '../../../core/theme/depth_tokens.dart';
import 'center_play_button.dart';
import 'chrome_panel.dart';
import 'chrome_top_bar.dart';
import 'panel_controls.dart';
import 'playback_surface.dart';
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
///
/// The pointer-left-the-window hide (below, in [build]) is gated on
/// `!PlatformFeatures.isMobile`, i.e. it is live on Flutter web as well as
/// native desktop, not desktop-only. That is deliberate: on web, moving the
/// cursor to the browser's tab strip or URL bar also collapses the auto-hide
/// timer to zero and hides the chrome mid-playback. A pointer that has left
/// the content area is nobody aiming at a control regardless of which chrome
/// (OS window or browser tab) it left into, and the same `MouseRegion`
/// already hides the mouse cursor itself on web for the same reason.
class ChromeVisibility extends StatefulWidget {
  /// Whether playback is running. Chrome never auto-hides while paused.
  final bool isPlaying;

  /// Whether the user is scrubbing. Chrome never auto-hides mid-seek.
  final bool isSeeking;

  final Widget child;

  final Duration autoHide;

  /// Toggles fullscreen on a background double-click. Null by default.
  ///
  /// The platform gate lives in [PlaybackChrome], not here. Registering a
  /// double-tap handler makes Flutter defer the single tap by
  /// `kDoubleTapTimeout`, and `flutter test` runs on Linux where
  /// `PlatformFeatures.isDesktop` is true, so gating here would silently add
  /// that deferral to every widget test that constructs this class directly.
  final VoidCallback? onDoubleTap;

  /// Starts an OS window drag from the background. Null by default.
  final VoidCallback? onWindowDrag;

  /// Hides/shows the macOS traffic-light window buttons in step with chrome
  /// visibility. Injected by tests; defaults to the real native bridge
  /// (`setTrafficLightsHidden` from `core/window/traffic_lights.dart`).
  final void Function(bool hidden)? onTrafficLightsHidden;

  const ChromeVisibility({
    super.key,
    required this.isPlaying,
    required this.child,
    this.isSeeking = false,
    this.autoHide = const Duration(seconds: 3),
    this.onDoubleTap,
    this.onWindowDrag,
    this.onTrafficLightsHidden,
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

  /// Whether the player's own route is still the top one, sampled in [build].
  ///
  /// Read in [build] rather than in the exit handler on purpose:
  /// `ModalRoute.of` registers an inherited-widget dependency, and
  /// `_ModalScopeStatus.updateShouldNotify` compares `isCurrent`, so sampling
  /// it here means this widget rebuilds when a selector opens or closes and
  /// the flag stays accurate without calling into the element tree from a
  /// pointer callback.
  bool _routeIsCurrent = true;

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
    // `_visible` starts true and `_show()` only calls the bridge on a
    // false -> true transition, so a freshly-mounted ChromeVisibility would
    // otherwise never assert "buttons are visible" to the native side. This
    // makes that invariant self-healing: even if some other bug left the
    // native buttons stranded hidden, the next mount (e.g. re-entering the
    // player) restores them. Safe to fire even if the app happens to
    // already be fullscreen at mount time — see shouldControlTrafficLights'
    // doc comment for why a restore always gets through.
    _setTrafficLightsHidden(false);
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
    _setTrafficLightsHidden(false);
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

  /// Resolves to the injected test callback, or the real native bridge.
  void Function(bool hidden) get _setTrafficLightsHidden =>
      widget.onTrafficLightsHidden ?? setTrafficLightsHidden;

  void _show() {
    if (!_visible) {
      setState(() => _visible = true);
      _setTrafficLightsHidden(false);
    }
    _controller.forward();
    _restartTimer();
  }

  void _hide() {
    _hideTimer?.cancel();
    if (_visible) {
      setState(() => _visible = false);
      _setTrafficLightsHidden(true);
    }
    _controller.reverse();
  }

  void _toggle() => _visible ? _hide() : _show();

  @override
  Widget build(BuildContext context) {
    _routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;

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
        PlaybackSurface(
          onTap: _toggle,
          onDoubleTap: widget.onDoubleTap,
          onWindowDrag: widget.onWindowDrag,
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
        onExit: (_) {
          // A pointer outside the window is nobody aiming at a control, so
          // collapse the auto-hide timer to zero. `_mayHide` still governs,
          // which is what preserves the paused, seeking and
          // pointer-over-chrome invariants. The 250ms reverse fade still
          // runs; "immediately" refers to the timer, not the animation.
          //
          // `_routeIsCurrent` keeps an open selector from hiding the chrome
          // underneath itself, which would leave it gone after dismissal
          // until the mouse moved again.
          //
          // `mounted` is checked because a test's `gesture.removePointer`
          // teardown, and a real window close, both synthesise an exit that
          // can arrive while this State is being torn down.
          if (mounted && _routeIsCurrent && _mayHide) _hide();
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
/// **Why double-tap ±10s (`gesture_controls.dart`) still works through
/// [ChromeVisibility]'s background tap-to-toggle catcher:** that catcher is
/// [PlaybackSurface] (a `Listener` wrapping an opaque `GestureDetector`) and
/// is the *first* child of this widget's `Stack` (see
/// `ChromeVisibility.build`), i.e. the bottom-most layer, not the topmost —
/// it only claims a tap that nothing painted above it wants. In production,
/// [PlaybackChrome] is never a `Stack` sibling of
/// `GestureControls`; it is the `controls` builder media_kit's `Video`
/// renders via `Positioned.fill` inside `Video`'s own internal `Stack`, and
/// `GestureControls` wraps that entire `Video` as its child, using
/// `HitTestBehavior.translucent` so its ancestor double-tap recognizer still
/// enters the arena underneath. `gesture_chrome_composition_test.dart`
/// exercises exactly this nesting against a fake platform player and would
/// fail if either the Stack order or `GestureControls`' hit-test behaviour
/// regressed. Do not restructure this nesting without re-reading that test.
class PlaybackChrome extends StatefulWidget {
  final Player player;
  final StreamTimeline timeline;

  /// Seeks to a real media position, restarting the HLS session when the
  /// target is beyond what has been transcoded so far. See
  /// `_PlayerScreenState.seekToReal`'s dartdoc for the full story.
  final Future<void> Function(Duration realTarget) onSeekToReal;

  final String? title;
  final VoidCallback? onBack;
  final Widget? castAction;
  final VoidCallback? onCastTap;

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

  const PlaybackChrome({
    super.key,
    required this.player,
    required this.timeline,
    required this.onSeekToReal,
    this.title,
    this.onBack,
    this.castAction,
    this.onCastTap,
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
  });

  @override
  State<PlaybackChrome> createState() => _PlaybackChromeState();
}

class _PlaybackChromeState extends State<PlaybackChrome> {
  bool _seeking = false;

  void _seekBy(Duration offset) {
    final player = widget.player;
    final timeline = widget.timeline;
    final duration = timeline.resolveDuration(player.state.duration);
    final target = timeline.toReal(player.state.position) + offset;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > duration ? duration : target);
    widget.onSeekToReal(clamped);
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
          // Both gates live here, not inside ChromeVisibility, so widget
          // tests can construct that class with plain callbacks and get
          // deterministic behaviour regardless of the host platform.
          //
          // Double-click stays available in fullscreen, since that is how
          // you get back out. The window drag does not: there is no window
          // to move.
          onDoubleTap:
              PlatformFeatures.isDesktop ? widget.onFullscreenTap : null,
          onWindowDrag: PlatformFeatures.isDesktop && !widget.isFullscreen
              ? startWindowDrag
              : null,
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
                      onCastTap: widget.onCastTap,
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
                          // Below the mobile breakpoint the in-bar transport
                          // is play/pause only (see
                          // `TransportSurface.compact`'s dartdoc for the full
                          // layout reasoning). `onPreviousEpisode`/
                          // `onNextEpisode` above are still passed through
                          // unconditionally — `compact` ignores them
                          // regardless — rather than gated to null here, so
                          // they reappear the moment the breakpoint is
                          // crossed without this widget needing to know why.
                          //
                          // NOTE, this is a real, currently-unresolved gap:
                          // unlike ±10s seek (which has an explicit gesture
                          // replacement, double-tap in
                          // `gesture_controls.dart`), episode nav has no
                          // touch-reachable equivalent once it's dropped
                          // from the bar. `UpNextOverlay` only offers *next*,
                          // and only near an episode's end; there is no
                          // touch path to the *previous* episode at all
                          // below this breakpoint. See this task's report for
                          // the open follow-up; do not read this comment as
                          // "handled".
                          compact: metrics.touchTargets,
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
                          // Passed through `metrics.showQuality` rather than
                          // bare, even though every tier shows it today: see
                          // that field's dartdoc — it stays a real per-tier
                          // lever for the tier that can't absorb a future
                          // 5th control.
                          onQualityTap:
                              metrics.showQuality ? widget.onQualityTap : null,
                          onFullscreenTap: widget.onFullscreenTap,
                          audioTrackCount: widget.audioTrackCount,
                          subtitleTrackCount: widget.subtitleTrackCount,
                          selectedAudioLabel: widget.selectedAudioLabel,
                          selectedSubtitleLabel: widget.selectedSubtitleLabel,
                          selectedQualityLabel: widget.selectedQualityLabel,
                          isFullscreen: widget.isFullscreen,
                          gap: metrics.secondaryGap,
                        ),
                        scrubber: _ScrubberRow(
                          player: widget.player,
                          timeline: widget.timeline,
                          onSeekToReal: widget.onSeekToReal,
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
  final StreamTimeline timeline;
  final Future<void> Function(Duration realTarget) onSeekToReal;
  final bool touchTargets;
  final VoidCallback onSeekStart;
  final VoidCallback onSeekEnd;

  const _ScrubberRow({
    required this.player,
    required this.timeline,
    required this.onSeekToReal,
    required this.touchTargets,
    required this.onSeekStart,
    required this.onSeekEnd,
  });

  /// Both timecodes share this style — deliberately identical. An earlier
  /// version styled elapsed at full white and remaining dimmer; that
  /// asymmetry measured as the single worst-case contrast on the whole
  /// panel (2.32:1) in an accessibility audit of this panel.
  ///
  /// `color` must stay fully opaque: `glass_legibility_test.dart` models the
  /// contrast contract assuming an opaque foreground composited with this
  /// shadow, and a translucent color (even a small drop, e.g. white @ 0.55)
  /// composites with the fill/shadow behind it and measures under the WCAG
  /// SC 1.4.3 text floor of 4.5:1 despite the test passing on the wrong
  /// (opaque) model — see that file's CenterPlayButton/timecode cases for
  /// why the drift went uncaught before.
  ///
  /// The shadow is load-bearing, not decorative: `glass_legibility_test.dart`
  /// measures the fill alone at this row's height as under the WCAG SC 1.4.3
  /// text floor of 4.5:1 — and comfortably above it with this exact shadow
  /// composited in. Never apply this treatment to an icon; row 1's icons stay
  /// unshadowed, held to the looser 3:1 non-text floor instead (see
  /// `DepthTokens.playerChromeFillTopAlpha`'s doc comment).
  static const TextStyle _timeStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: Colors.white,
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
            final position = timeline.toReal(
              positionSnapshot.data ?? Duration.zero,
            );
            final duration = timeline.resolveDuration(
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
                    timeline: timeline,
                    onSeekToReal: onSeekToReal,
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
