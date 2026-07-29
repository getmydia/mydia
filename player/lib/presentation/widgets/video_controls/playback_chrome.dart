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

class _ChromeVisibilityState extends State<ChromeVisibility>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _hideTimer;
  bool _pointerOverChrome = false;

  /// Authoritative shown/hidden intent.
  ///
  /// Deliberately **not** derived from `_controller.value > 0` (the brief's
  /// original approach), which hid two real defects: (1) [IgnorePointer]'s
  /// `ignoring` arg and the cursor style below are computed inside this
  /// State's `build()`, which only reruns on `setState` — never on a bare
  /// animation tick, since nothing here is an `AnimatedBuilder` listening to
  /// [_controller] directly. A value derived from `_controller.value` would
  /// therefore freeze at whatever it read on the last actual rebuild: chrome
  /// fades to invisible while silently staying interactive underneath,
  /// swallowing taps meant for the background toggle. (2) `_controller.value
  /// > 0` stays true for nearly the whole 250ms hide fade, so a tap arriving
  /// mid-fade read as "still visible" and called [_hide] again instead of
  /// restoring the chrome. A plain field flipped inside `setState` the
  /// instant [_show]/[_hide] is invoked fixes both.
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
      widget.onVisibilityChanged?.call(true);
    }
    _controller.forward();
    _restartTimer();
  }

  void _hide() {
    _hideTimer?.cancel();
    if (_visible) {
      setState(() => _visible = false);
      widget.onVisibilityChanged?.call(false);
    }
    _controller.reverse();
  }

  void _toggle() => _visible ? _hide() : _show();

  @override
  Widget build(BuildContext context) {
    final content = ChromeAnimation(
      animation: _controller,
      child: FadeTransition(
        opacity: _controller,
        // IgnorePointer wraps MouseRegion (not the other way around) on
        // purpose. MouseRegion defaults to `opaque: true`: it self-registers
        // a hit across its *entire* geometry regardless of whether any
        // descendant is actually hit, which is exactly what row-spanning
        // hover detection needs (the pointer often rests over plain padding,
        // not a widget with its own hit target). But that opaqueness means
        // if MouseRegion sat *outside* IgnorePointer, it would keep
        // reporting a hit here even while `ignoring` is true, making the
        // enclosing Stack think this whole subtree was hit and stop before
        // ever falling through to the background tap-to-reveal catcher below
        // — silently breaking "tap to bring chrome back" for as long as
        // chrome stays hidden (confirmed by trying that ordering: it broke
        // the brief's own "reappears on tap after hiding" test). With
        // IgnorePointer outermost, `ignoring: true` short-circuits before
        // MouseRegion is ever reached, so hidden chrome correctly falls
        // through. The trade-off — no onEnter/onExit while hidden — is fine:
        // hidden chrome has nothing left to protect from auto-hiding, and
        // Flutter's mouse tracker re-evaluates hit-test annotations on the
        // next frame once `ignoring` flips back to false, so a cursor
        // already resting over the content is correctly picked up the
        // instant chrome reappears (see "keeps chrome shown once the mouse
        // re-enters after it reappears" below).
        child: IgnorePointer(
          ignoring: !_visible,
          child: MouseRegion(
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
        onHover: (_) => _show(),
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
                        // Passed unconditionally per ChromePanel's own
                        // contract (see its `volume` dartdoc): ChromePanel
                        // already gates visibility internally with a
                        // `Visibility(maintainState: true)` so
                        // VolumeCluster's `_lastVolume` survives a breakpoint
                        // crossing. Gating construction here on
                        // `metrics.showVolume` instead would rebuild
                        // VolumeCluster from scratch on every crossing,
                        // silently dropping the remembered pre-mute volume.
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
