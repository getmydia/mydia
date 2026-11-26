import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';
import 'package:player/presentation/widgets/glass/dry_liquid_glass.dart';

import 'lab_glass.dart';

/// The playback OSD on two painted frames, bright and dark, each drawn twice:
/// sampled glass (the shader over the picture, iOS and macOS texture output)
/// and dry glass (macOS native surface output, no sampling).
///
/// The real bars import providers and plugins the lab's scratch project does
/// not have, so this builds the OSD from its glass pieces: lens pills with
/// white glyphs (back and title share one), the bottom scrim with its eased
/// fade into the OSD fill plateau (as `ChromeScrim` draws it in every mode,
/// with no top band), the circular glass play disc, the timecodes and
/// controls straight on the scrim, the scrubber with its plain white thumb,
/// and an up next panel. The
/// sampled tints and the dry recipe are the ones `GlassSurface._osdGlass`
/// uses. Every word is invented.
class OsdScene extends StatelessWidget {
  const OsdScene({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    children: [
      Expanded(
        child: Row(
          children: [
            Expanded(child: _Cell(bright: true, dry: false)),
            Expanded(child: _Cell(bright: true, dry: true)),
          ],
        ),
      ),
      Expanded(
        child: Row(
          children: [
            Expanded(child: _Cell(bright: false, dry: false)),
            Expanded(child: _Cell(bright: false, dry: true)),
          ],
        ),
      ),
    ],
  );
}

const _white = Color(0xFFFFFFFF);

class _Cell extends StatelessWidget {
  const _Cell({required this.bright, required this.dry});

  final bool bright;
  final bool dry;

  Widget _pill(double radius, Widget child) => dry
      ? DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: LiquidGlassProfile.lens.shadow,
          ),
          child: DryLiquidGlass(
            borderRadius: BorderRadius.circular(radius),
            tint: DepthTokens.osdTint.withValues(
              alpha: DepthTokens.osdDryTintOpacity,
            ),
            profile: LiquidGlassProfile.lens,
            child: child,
          ),
        )
      : labGlass(
          radius,
          DepthTokens.osdTint,
          DepthTokens.liquidControlTintOpacity,
          adaptiveMax: DepthTokens.liquidControlAdaptiveMax,
          child: child,
        );

  Widget _panel(double radius, Widget child) => dry
      ? DryLiquidGlass(
          borderRadius: BorderRadius.circular(radius),
          tint: DepthTokens.osdTint.withValues(
            alpha: DepthTokens.osdDryPanelTintOpacity,
          ),
          profile: LiquidGlassProfile.panel,
          child: child,
        )
      : labGlass(
          radius,
          DepthTokens.osdTint,
          DepthTokens.liquidModalTintOpacity,
          adaptiveMax: DepthTokens.liquidModalAdaptiveMax,
          profile: LiquidGlassProfile.panel,
          child: child,
        );

  Widget _icons(List<IconData> icons, {double size = 22}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final icon in icons)
        SizedBox(
          width: 44,
          height: 40,
          child: Icon(icon, color: _white, size: size),
        ),
    ],
  );

  /// The scrubber thumb: Material's white dot in every mode, as the real
  /// progress bar draws it. A clear knob over the white played track
  /// vanished (spec, "Revision after #1525").
  Widget _thumb() => Container(
    width: 14,
    height: 14,
    decoration: const BoxDecoration(
      color: _white,
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 6)],
    ),
  );

  /// The bottom scrim as `ChromeScrim` builds it: an eased fade over
  /// [_fade], then the OSD fill solid behind the bar.
  static LinearGradient _scrim() {
    final plateau = DepthTokens.osdTint.withValues(
      alpha: DepthTokens.osdFillOpacity,
    );
    const steps = 12;
    const plateauStart = _fade / (_plateau + _fade);
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        for (var i = 0; i <= steps; i++)
          plateau.withValues(
            alpha: plateau.a * Curves.easeInOut.transform(i / steps),
          ),
        plateau,
      ],
      stops: [for (var i = 0; i <= steps; i++) i / steps * plateauStart, 1],
    );
  }

  static const double _plateau = 96;
  static const double _fade = 40;

  static const _timecode = TextStyle(
    color: _white,
    fontSize: 12,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(child: _Frame(bright: bright)),
          // The scrim: bottom band only, solid behind the bar in every mode.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: _plateau + _fade,
            child: DecoratedBox(decoration: BoxDecoration(gradient: _scrim())),
          ),
          // Back and the title share one pill.
          Positioned(
            top: 14,
            left: 14,
            child: _pill(
              18,
              const SizedBox(
                height: 36,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 40,
                      child: Icon(
                        Icons.chevron_left_rounded,
                        color: _white,
                        size: 22,
                      ),
                    ),
                    Padding(
                      padding: EdgeInsetsDirectional.only(start: 2, end: 14),
                      child: Text(
                        'Harbor Lights',
                        style: TextStyle(
                          color: _white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 14,
            right: 14,
            child: _pill(
              18,
              _icons(const [Icons.fit_screen_rounded, Icons.cast_rounded]),
            ),
          ),
          // Touch transport: skip pills around the play disc.
          Positioned.fill(
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _pill(
                    24,
                    const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.replay_10, color: _white, size: 26),
                    ),
                  ),
                  const SizedBox(width: 24),
                  _pill(
                    36,
                    const SizedBox(
                      width: 72,
                      height: 72,
                      child: Icon(Icons.pause_rounded, color: _white, size: 40),
                    ),
                  ),
                  const SizedBox(width: 24),
                  _pill(
                    24,
                    const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.forward_10, color: _white, size: 26),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Up next.
          Positioned(
            right: 14,
            bottom: 96,
            width: 170,
            child: _panel(
              16,
              const Padding(
                padding: EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Up next',
                      style: TextStyle(color: _white, fontSize: 11),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'S1 E3 · Harbor Lights',
                      style: TextStyle(
                        color: _white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Timeline row on the scrim: elapsed, the scrubber, remaining.
          // Neither the track nor the thumb takes glass.
          Positioned(
            left: 14,
            right: 14,
            bottom: 56,
            height: 28,
            child: Row(
              children: [
                const Text('12:04', style: _timecode),
                const SizedBox(width: 12),
                Expanded(
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: _white.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: 0.4,
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: _white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Align(
                        alignment: const Alignment(-0.2, 0),
                        child: _thumb(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                const Text('-31:56', style: _timecode),
              ],
            ),
          ),
          // Control row on the scrim, no pill: volume left, the secondary
          // cluster right.
          Positioned(
            left: 14,
            right: 14,
            bottom: 12,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _icons(const [Icons.volume_up_rounded]),
                _icons(const [
                  Icons.closed_caption_outlined,
                  Icons.speed,
                  Icons.fullscreen_rounded,
                ]),
              ],
            ),
          ),
          labTag(
            top: 60,
            left: 14,
            text: '${bright ? 'bright' : 'dark'} / ${dry ? 'dry' : 'sampled'}',
          ),
        ],
      ),
    );
  }
}

/// A painted frame: a near-white sky or a dark night, with a few shapes and
/// fine detail so the sampled glass has something to bend.
class _Frame extends StatelessWidget {
  const _Frame({required this.bright});

  final bool bright;

  @override
  Widget build(BuildContext context) {
    final top = bright ? const Color(0xFFFFFFFF) : const Color(0xFF05060C);
    final bottom = bright ? const Color(0xFFF2EEE4) : const Color(0xFF16121C);
    final shape = bright ? const Color(0xFFD8D2C4) : const Color(0xFF3B2A52);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ),
      ),
      child: CustomPaint(painter: _ShapePainter(shape, bright)),
    );
  }
}

class _ShapePainter extends CustomPainter {
  _ShapePainter(this.shape, this.bright);

  final Color shape;
  final bool bright;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = shape;
    canvas.drawCircle(Offset(size.width * 0.25, size.height * 0.35), 46, p);
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.55, size.height * 0.3, 90, 90),
      p,
    );
    final line = Paint()
      ..color = bright ? const Color(0xFF8A8478) : const Color(0xFF9A8CB8)
      ..strokeWidth = 1;
    for (var y = 0.0; y < size.height; y += 14) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(_ShapePainter old) => false;
}
