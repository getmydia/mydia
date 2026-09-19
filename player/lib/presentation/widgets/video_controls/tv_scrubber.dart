import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/player/scrub_controller.dart';

/// The remote tier's progress bar focus stop.
///
/// Turns D-pad keys into [ScrubController] calls. Left and right move the
/// cursor, press and hold alike. OK commits. Play/Pause commits and then
/// toggles playback. Up and down commit and are left unhandled, so focus
/// traversal still carries the viewer to the transport row. Losing focus any
/// other way commits too: a cursor the viewer can no longer see must not sit
/// waiting for the idle timer.
///
/// With the runtime unknown there is nothing to scrub, and left and right
/// fall through to focus traversal as they did before the bar took focus.
class TvScrubber extends StatefulWidget {
  const TvScrubber({
    super.key,
    required this.scrub,
    required this.focusNode,
    required this.onPlayPause,
    required this.builder,
  });

  final ScrubController scrub;
  final FocusNode focusNode;
  final VoidCallback onPlayPause;

  /// Builds the bar, told whether it currently holds focus.
  final Widget Function(BuildContext context, bool focused) builder;

  @override
  State<TvScrubber> createState() => _TvScrubberState();
}

class _TvScrubberState extends State<TvScrubber> {
  late bool _focused = widget.focusNode.hasFocus;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final isRepeat = event is KeyRepeatEvent;
    final scrub = widget.scrub;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        return _step(ScrubDirection.backward, isRepeat);
      case LogicalKeyboardKey.arrowRight:
        return _step(ScrubDirection.forward, isRepeat);
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.arrowDown:
        _commit();
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.gameButtonA:
        if (isRepeat || !scrub.active) return KeyEventResult.ignored;
        _commit();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaPlayPause:
        if (isRepeat || !scrub.active) return KeyEventResult.ignored;
        _commit();
        widget.onPlayPause();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  KeyEventResult _step(ScrubDirection direction, bool isRepeat) =>
      widget.scrub.step(direction, isRepeat: isRepeat)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;

  void _commit() {
    if (widget.scrub.active) unawaited(widget.scrub.commit());
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKeyEvent,
      onFocusChange: (focused) {
        if (mounted) setState(() => _focused = focused);
        if (!focused) _commit();
      },
      child: widget.builder(context, _focused),
    );
  }
}
