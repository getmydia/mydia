import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection_provider.dart';
import '../../core/connection/connection_summary.dart';
import '../../core/p2p/p2p_service.dart';
import '../../core/theme/colors.dart';
import 'connection_tone_color.dart';

/// A small status dot describing the current connection, with the summary
/// label as its tooltip.
///
/// Extracted from `app_shell.dart`, where it was private and therefore
/// untestable, and where it carried a third copy of the transport switch.
class ConnectionStatusDot extends ConsumerWidget {
  /// Whether an app update is waiting.
  ///
  /// Carried on shape rather than colour, because colour already means
  /// connection tone here and two meanings on one channel is one meaning.
  final bool updatePending;

  const ConnectionStatusDot({super.key, this.updatePending = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isP2P = ref.watch(connectionProvider).isP2PMode;
    final status = ref.watch(p2pStatusNotifierProvider);

    final summary = ConnectionSummary.from(
      isP2P: isP2P,
      type: status.peerConnectionType,
      isInitialized: status.isInitialized,
    );
    final color = connectionToneColor(summary.tone);
    final tooltip =
        updatePending ? 'Update available - ${summary.label}' : summary.label;

    // Pulse only while re-establishing a link that was previously up. A first
    // connection is pending too, but a pulsing dot at launch reads as a fault.
    if (summary.tone == ConnectionTone.pending && status.isInitialized) {
      return _PulsingDot(
        color: color,
        tooltip: tooltip,
        updatePending: updatePending,
      );
    }

    return _Dot(color: color, tooltip: tooltip, updatePending: updatePending);
  }
}

class _Dot extends StatelessWidget {
  const _Dot({
    required this.color,
    required this.tooltip,
    required this.updatePending,
  });

  final Color color;
  final String tooltip;
  final bool updatePending;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: updatePending ? 14 : 10,
        height: updatePending ? 14 : 10,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(color: AppColors.surface, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.4),
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
        child: updatePending
            ? const Icon(Icons.arrow_upward, size: 9, color: AppColors.surface)
            : null,
      ),
    );
  }
}

/// A pulsing dot indicating reconnection in progress.
///
/// The colour is whatever the caller passes, which today is the pending tone.
/// It is deliberately not named here: the tone-to-colour mapping lives in
/// [connectionToneColor] and this comment would go stale the moment it moved.
///
/// Animation values and shape preserved from the former private shell widget
/// (`AnimatedBuilder` + `Opacity`, 1200ms) rather than the plan's
/// `FadeTransition` sketch.
class _PulsingDot extends StatefulWidget {
  final Color color;
  final String tooltip;
  final bool updatePending;

  const _PulsingDot({
    required this.color,
    required this.tooltip,
    required this.updatePending,
  });

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final opacity = 0.4 + (_controller.value * 0.6);
          return Opacity(
            opacity: opacity,
            child: Container(
              width: widget.updatePending ? 14 : 10,
              height: widget.updatePending ? 14 : 10,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color,
                border: Border.all(
                  color: AppColors.surface,
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.4),
                    blurRadius: 4,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: widget.updatePending
                  ? const Icon(
                      Icons.arrow_upward,
                      size: 9,
                      color: AppColors.surface,
                    )
                  : null,
            ),
          );
        },
      ),
    );
  }
}
