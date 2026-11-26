import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';
import 'package:player/presentation/widgets/glass/dry_liquid_glass.dart';
import 'package:player/presentation/widgets/glass/liquid_glass_filter.dart';

import 'lab_glass.dart';

/// The playback OSD on two painted frames, bright and dark, each drawn twice:
/// sampled glass (the shader over the picture, iOS and macOS texture output)
/// and dry glass (macOS native surface output, no sampling).
///
/// The real bars import providers and plugins the lab's scratch project does
/// not have, so this builds the OSD from its glass pieces: lens pills with
/// white glyphs, the gradient-only scrim at `osdLiquidScrimOpacity`, the
/// circular play disc, the clear scrubber knob and an up next panel. The
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

  Widget _knob() {
    const size = 22.0;
    final radius = BorderRadius.circular(size / 2);
    const fill = ColoredBox(
      color: Color.fromRGBO(255, 255, 255, DepthTokens.liquidKnobFillOpacity),
      child: SizedBox.expand(),
    );
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: LiquidGlassProfile.clear.shadow,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: dry
              ? DryLiquidGlass(
                  borderRadius: radius,
                  tint: const Color.fromRGBO(
                    255,
                    255,
                    255,
                    DepthTokens.liquidKnobFillOpacity,
                  ),
                  profile: LiquidGlassProfile.clear,
                )
              : const LiquidGlassFilter(
                  radius: size / 2,
                  tint: Color(0x00FFFFFF),
                  profile: LiquidGlassProfile.clear,
                  child: fill,
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final edge = DepthTokens.osdTint.withValues(
      alpha: DepthTokens.osdLiquidScrimOpacity,
    );
    final clear = edge.withValues(alpha: 0);
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(child: _Frame(bright: bright)),
          // The glass-mode scrim: edge opacity fading to nothing, no plateau.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 110,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [edge, clear],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 130,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [edge, clear],
                ),
              ),
            ),
          ),
          Positioned(
            top: 14,
            left: 14,
            child: _pill(18, _icons(const [Icons.arrow_back])),
          ),
          Positioned(
            top: 14,
            right: 14,
            child: _pill(
              18,
              _icons(const [
                Icons.closed_caption_outlined,
                Icons.speed,
                Icons.more_horiz,
              ]),
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
          // Scrubber: the track never takes glass; the knob does.
          Positioned(
            left: 24,
            right: 24,
            bottom: 62,
            height: 22,
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
                Align(alignment: const Alignment(-0.2, 0), child: _knob()),
              ],
            ),
          ),
          Positioned(
            left: 14,
            bottom: 12,
            child: _pill(
              18,
              _icons(const [
                Icons.skip_previous_rounded,
                Icons.skip_next_rounded,
                Icons.volume_up_rounded,
                Icons.fullscreen_rounded,
              ]),
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
