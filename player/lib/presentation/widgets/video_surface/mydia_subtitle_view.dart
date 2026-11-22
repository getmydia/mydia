import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show SubtitleViewConfiguration;

/// Moves a [MydiaSubtitleView]'s padding from outside the widget tree, the
/// way `VideoState.setSubtitleViewPadding` does for media_kit's `SubtitleView`.
class MydiaSubtitleViewController {
  _MydiaSubtitleViewState? _state;

  /// Sets the subtitles' padding, animated over [duration]. A no-op while no
  /// view is attached.
  void setPadding(EdgeInsets padding, {required Duration duration}) =>
      _state?._setPadding(padding, duration);

  /// Returns to the configuration's padding, animated over [duration].
  void resetPadding({required Duration duration}) =>
      _state?._setPadding(null, duration);
}

/// Draws text subtitles from a [Player] alone.
///
/// media_kit_video's `SubtitleView` needs a `VideoController`, which the
/// macOS native video surface does not have. This follows it (text style,
/// `textScaler`, animated padding) but reads only `player.state.subtitle`
/// and `player.stream.subtitle`.
class MydiaSubtitleView extends StatefulWidget {
  const MydiaSubtitleView({
    super.key,
    required this.player,
    required this.configuration,
    this.controller,
  });

  final Player player;
  final SubtitleViewConfiguration configuration;
  final MydiaSubtitleViewController? controller;

  @override
  State<MydiaSubtitleView> createState() => _MydiaSubtitleViewState();
}

class _MydiaSubtitleViewState extends State<MydiaSubtitleView> {
  static const _referenceWidth = 1920.0;
  static const _referenceHeight = 1080.0;

  late List<String> _subtitle = widget.player.state.subtitle;

  /// The controller's padding; the configuration's applies until it sets one.
  EdgeInsets? _liftedPadding;
  Duration _duration = const Duration(milliseconds: 100);
  StreamSubscription<List<String>>? _subscription;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _listen();
  }

  @override
  void didUpdateWidget(MydiaSubtitleView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller?._state == this) old.controller?._state = null;
      widget.controller?._state = this;
    }
    if (old.player != widget.player) {
      _subscription?.cancel();
      _subtitle = widget.player.state.subtitle;
      _listen();
    }
  }

  void _listen() {
    _subscription = widget.player.stream.subtitle.listen((value) {
      if (mounted) setState(() => _subtitle = value);
    });
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    _subscription?.cancel();
    super.dispose();
  }

  void _setPadding(EdgeInsets? padding, Duration duration) {
    if (!mounted) return;
    setState(() {
      _duration = duration;
      _liftedPadding = padding;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = constraints.maxWidth * constraints.maxHeight;
        final scale = math.sqrt(
          (area / (_referenceWidth * _referenceHeight)).clamp(0.0, 1.0),
        );
        final textScaler =
            widget.configuration.textScaler ?? TextScaler.linear(scale);
        return Material(
          color: Colors.transparent,
          child: AnimatedContainer(
            padding: _liftedPadding ?? widget.configuration.padding,
            duration: _duration,
            alignment: Alignment.bottomCenter,
            child: Text(
              [
                for (final line in _subtitle)
                  if (line.trim().isNotEmpty) line.trim(),
              ].join('\n'),
              style: widget.configuration.style,
              textAlign: widget.configuration.textAlign,
              textScaler: textScaler,
            ),
          ),
        );
      },
    );
  }
}
