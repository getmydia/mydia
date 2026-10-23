import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';

import 'lab_glass.dart';

const _ground = Color(0xFF101014);

Widget _control(double radius, {Widget child = const SizedBox.expand()}) =>
    labGlass(radius, _ground, DepthTokens.liquidControlTintOpacity,
        adaptiveMax: DepthTokens.liquidControlAdaptiveMax, child: child);

/// Poster-like artwork: a night sky, saturated shapes and small text, so the
/// glass is judged over the kind of backdrop the detail hero has. Painted,
/// never a real image, and every word is invented.
class ArtworkBackdrop extends StatelessWidget {
  const ArtworkBackdrop({super.key});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _ArtworkPainter(), size: Size.infinite);
}

class _ArtworkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B1030), Color(0xFF2A1240), Color(0xFF070709)],
          stops: [0, 0.55, 1],
        ).createShader(rect),
    );
    final random = math.Random(7);
    final star = Paint()..color = Colors.white.withValues(alpha: 0.8);
    for (var i = 0; i < 220; i++) {
      canvas.drawCircle(
        Offset(random.nextDouble() * size.width,
            random.nextDouble() * size.height * 0.6),
        random.nextDouble() * 1.4 + 0.3,
        star,
      );
    }
    canvas.drawCircle(
      Offset(size.width * 0.78, size.height * 0.18),
      70,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFFFFF4D6), Color(0x00FFF4D6)],
        ).createShader(Rect.fromCircle(
            center: Offset(size.width * 0.78, size.height * 0.18), radius: 70)),
    );
    const bands = [
      Color(0xFFE94F8A),
      Color(0xFF39C6E8),
      Color(0xFFF2B33D),
      Color(0xFF6CE07A),
    ];
    for (var i = 0; i < bands.length; i++) {
      final path = Path()
        ..moveTo(0, size.height * (0.45 + i * 0.08))
        ..lineTo(size.width, size.height * (0.25 + i * 0.08))
        ..lineTo(size.width, size.height * (0.29 + i * 0.08))
        ..lineTo(0, size.height * (0.49 + i * 0.08))
        ..close();
      canvas.drawPath(path, Paint()..color = bands[i].withValues(alpha: 0.85));
    }
    for (var line = 0; line < 9; line++) {
      final painter = TextPainter(
        text: TextSpan(
          text: 'The lantern keeper of Velmora counts the tides at dusk '
              'while the harbour bells answer from across the bay.',
          style: TextStyle(
            color: line.isEven ? Colors.white : Colors.black,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - 40);
      painter.paint(canvas, Offset(20, 300 + line * 34.0));
    }
  }

  @override
  bool shouldRepaint(_ArtworkPainter oldDelegate) => false;
}

/// The detail screen's floating controls over [ArtworkBackdrop].
class ArtworkScene extends StatelessWidget {
  const ArtworkScene({super.key});

  static const _actions = [
    Icons.check_circle_outline,
    Icons.favorite_border,
    Icons.download_rounded,
    Icons.smart_display_outlined,
    Icons.info_outline,
  ];

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: ArtworkBackdrop()),
        Positioned(
          top: 24,
          left: 24,
          width: 44,
          height: 44,
          child: _control(22,
              child: const Icon(Icons.arrow_back, color: Colors.white)),
        ),
        Positioned(
          top: 24,
          right: 24,
          width: 44,
          height: 44,
          child:
              _control(22, child: const Icon(Icons.cast, color: Colors.white)),
        ),
        Positioned(
          top: 300,
          left: 40,
          width: 190,
          height: 34,
          child: _control(17,
              child: const Center(
                child: Text(
                  'Next Up · S1 E3',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600),
                ),
              )),
        ),
        Positioned(
          top: 300,
          left: 260,
          width: 180,
          height: 50,
          child: _control(25,
              child:
                  labLabel(Icons.play_arrow_rounded, 'Resume', fontSize: 18)),
        ),
        for (var i = 0; i < _actions.length; i++)
          Positioned(
            top: 390,
            left: 40 + i * 76.0,
            width: 44,
            height: 44,
            child: _control(22,
                child: Icon(_actions[i], color: Colors.white, size: 22)),
          ),
        for (var i = 0; i < 2; i++)
          Positioned(
            top: 470,
            left: 40 + i * 110.0,
            width: 96,
            height: 34,
            child: _control(17,
                child: Center(
                  child: Text(
                    i == 0 ? 'Drama' : 'Mystery',
                    style: const TextStyle(color: Colors.white),
                  ),
                )),
          ),
        Positioned(
          left: 330,
          right: 330,
          bottom: 24,
          height: 62,
          child: labGlass(31, _ground, DepthTokens.liquidChromeTintOpacity,
              adaptiveMax: DepthTokens.liquidChromeAdaptiveMax,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Icon(Icons.home_rounded, color: Colors.white),
                  Icon(Icons.movie_outlined, color: Colors.white),
                  Icon(Icons.tv_rounded, color: Colors.white),
                  Icon(Icons.download_rounded, color: Colors.white),
                  Icon(Icons.settings_outlined, color: Colors.white),
                ],
              )),
        ),
        labTag(top: 284, left: 40, text: 'badge 34pt'),
        labTag(top: 284, left: 260, text: 'lens 50pt'),
        labTag(top: 374, left: 40, text: 'actions 44pt'),
        labTag(top: 454, left: 40, text: 'chips 34pt'),
      ],
    );
  }
}

/// A dialog and the floating sidebar (panel profile) over [ArtworkBackdrop].
class PanelScene extends StatelessWidget {
  const PanelScene({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: ArtworkBackdrop()),
        Positioned(
          top: 24,
          left: 24,
          bottom: 24,
          width: 300,
          child: labGlass(28, _ground, DepthTokens.liquidChromeTintOpacity,
              adaptiveMax: DepthTokens.liquidChromeAdaptiveMax,
              profile: LiquidGlassProfile.panel),
        ),
        Positioned(
          top: 200,
          left: 520,
          width: 360,
          height: 220,
          child: labGlass(34, _ground, DepthTokens.liquidModalTintOpacity,
              adaptiveMax: DepthTokens.liquidModalAdaptiveMax,
              profile: LiquidGlassProfile.panel),
        ),
        labTag(top: 8, left: 24, text: 'sidebar (panel)'),
        labTag(top: 184, left: 520, text: 'dialog (panel)'),
      ],
    );
  }
}
