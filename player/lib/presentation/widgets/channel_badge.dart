import 'package:flutter/material.dart';

import '../../core/build_channel.dart';

/// A small BETA or DEV pill shown beside the app's wordmark, so a prerelease
/// build is recognisable inside the app. Renders nothing on stable.
///
/// Deliberately not focusable: on TV, D-pad focus must never land on it.
class ChannelBadge extends StatelessWidget {
  const ChannelBadge({super.key, this.channel});

  /// Null means the running build's channel. Tests pass one explicitly.
  final BuildChannel? channel;

  static const _amber = Color(0xFFF59E0B);
  static const _red = Color(0xFFEF4444);

  @override
  Widget build(BuildContext context) {
    final resolved = channel ?? BuildChannel.current;
    final label = resolved.badgeLabel;
    if (label == null) return const SizedBox.shrink();

    final isBeta = resolved == BuildChannel.beta;
    return Container(
      key: const ValueKey('channel-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isBeta ? _amber : _red,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: isBeta ? const Color(0xFF0F172A) : Colors.white,
        ),
      ),
    );
  }
}
