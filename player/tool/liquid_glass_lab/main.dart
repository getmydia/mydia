// Dev-only lab for the Liquid Glass shader. Not part of the app.
//
//   ./dev flutter run -d linux -t tool/liquid_glass_lab/main.dart
//
// On a Mac: `flutter run -d macos -t tool/liquid_glass_lab/main.dart`.
// Scroll the backdrop under the glass; toggle the grid to check the rim
// lines up with the clip edge.
//
// Headless snapshot mode (no screenshot tool needed), via --dart-define:
//   LAB_SNAPSHOT=<path.png>  write the lab to a PNG after the first frame
//                            plus 600 ms, print the result, then exit.
//   LAB_GRID=true            start with the grid backdrop.
//   LAB_SCROLL=<pixels>      initial scroll offset of the backdrop.
//   LAB_SCENE=<grid|artwork|panel>  which scene to draw (default grid).
//
// Every LAB_* value can also come from the process environment, which is how
// `./dev player glass-diff` runs one release build per scene.
//
//   xvfb-run -a ./dev flutter run -d linux \
//     --dart-define=LAB_SNAPSHOT=/tmp/lab.png -t tool/liquid_glass_lab/main.dart
//
// The player app itself does not build on Linux without libsecret, so to run
// the lab on Linux copy it plus the glass files (see docs/liquid-glass.md) into a plugin-free
// scratch Flutter project; `GDK_SCALE=2` gives a 2x DPR under xvfb.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';

import 'artwork_scene.dart';
import 'lab_glass.dart';

/// A LAB_* value from the process environment, else from --dart-define.
String _define(String key, String compiled) =>
    Platform.environment[key] ?? compiled;

final String _snapshotPath =
    _define('LAB_SNAPSHOT', const String.fromEnvironment('LAB_SNAPSHOT'));
final bool _initialGrid =
    _define('LAB_GRID', const String.fromEnvironment('LAB_GRID')) == 'true';
final String _scrollDefine =
    _define('LAB_SCROLL', const String.fromEnvironment('LAB_SCROLL'));
final String _scene =
    _define('LAB_SCENE', const String.fromEnvironment('LAB_SCENE'));

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassSupport.initialize();
  debugPrint('LAB shader=${LiquidGlassSupport.available}');
  runApp(const _Lab());
}

class _Lab extends StatefulWidget {
  const _Lab();

  @override
  State<_Lab> createState() => _LabState();
}

class _LabState extends State<_Lab> {
  final GlobalKey _captureKey = GlobalKey();
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: double.tryParse(_scrollDefine) ?? 0,
  );
  bool _grid = _initialGrid;

  @override
  void initState() {
    super.initState();
    if (_snapshotPath.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await _snapshot();
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _snapshot() async {
    try {
      final boundary = _captureKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        debugPrint('LAB_SNAPSHOT failed: no render boundary');
        exit(1);
      }
      final image = await boundary.toImage(
        pixelRatio: View.of(context).devicePixelRatio,
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        debugPrint('LAB_SNAPSHOT failed: PNG encoding returned null');
        exit(1);
      }
      await File(_snapshotPath).writeAsBytes(data.buffer.asUint8List());
      debugPrint(
        'LAB_SNAPSHOT wrote $_snapshotPath '
        'shader=${LiquidGlassSupport.available}',
      );
      exit(0);
    } catch (e) {
      debugPrint('LAB_SNAPSHOT failed: $e');
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: RepaintBoundary(
          key: _captureKey,
          child: switch (_scene) {
            'artwork' => const ArtworkScene(),
            'panel' => const PanelScene(),
            _ => _gridScene(),
          },
        ),
      ),
    );
  }

  Widget _gridScene() => Stack(
        children: [
          Positioned.fill(
            child: _Backdrop(grid: _grid, controller: _scroll),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 88,
            child: labGlass(
                0, const Color(0xFF101014), DepthTokens.liquidChromeTintOpacity,
                adaptiveMax: DepthTokens.liquidChromeAdaptiveMax),
          ),
          Positioned(
            top: 140,
            left: 40,
            width: 44,
            height: 44,
            child: labGlass(22, const Color(0xFF101014),
                DepthTokens.liquidControlTintOpacity,
                adaptiveMax: DepthTokens.liquidControlAdaptiveMax),
          ),
          Positioned(
            top: 140,
            left: 110,
            width: 160,
            height: 48,
            child: labGlass(24, const Color(0xFFFFFFFF),
                DepthTokens.liquidProminentTintOpacity),
          ),
          Positioned(
            top: 240,
            left: 40,
            width: 320,
            height: 200,
            // A dialog: the panel profile.
            child: labGlass(
                28, const Color(0xFF101014), DepthTokens.liquidModalTintOpacity,
                adaptiveMax: DepthTokens.liquidModalAdaptiveMax,
                profile: LiquidGlassProfile.panel),
          ),
          // A white strip: the worst case for white labels. Both
          // controls carry a white label so legibility is visible.
          const Positioned(
            top: 470,
            left: 0,
            right: 0,
            height: 120,
            child: ColoredBox(color: Colors.white),
          ),
          Positioned(
            top: 500,
            left: 40,
            width: 120,
            height: 48,
            child: labGlass(24, const Color(0xFF101014),
                DepthTokens.liquidControlTintOpacity,
                adaptiveMax: DepthTokens.liquidControlAdaptiveMax,
                child: labLabel(Icons.play_arrow_rounded, 'Play')),
          ),
          Positioned(
            top: 500,
            left: 190,
            width: 140,
            height: 48,
            child: labGlass(24, const Color(0xFF101014),
                DepthTokens.liquidControlTintOpacity,
                adaptiveMax: DepthTokens.liquidControlAdaptiveMax,
                child: labLabel(Icons.play_arrow_rounded, 'Play')),
          ),
          // The app bar's scroll edge band, as `GlassSurface._scrollEdge`
          // builds it, with two glass chips on its lower part.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 120,
            child: _scrollEdgeBand(),
          ),
          Positioned(
            top: 76,
            left: 16,
            width: 96,
            height: 32,
            child: labGlass(16, const Color(0xFF101014),
                DepthTokens.liquidControlTintOpacity,
                adaptiveMax: DepthTokens.liquidControlAdaptiveMax),
          ),
          Positioned(
            top: 76,
            left: 124,
            width: 96,
            height: 32,
            child: labGlass(16, const Color(0xFF101014),
                DepthTokens.liquidControlTintOpacity,
                adaptiveMax: DepthTokens.liquidControlAdaptiveMax),
          ),
          // Clear glass: a slider-style knob (37x24, radius 12) over a
          // 6pt track, and a 50pt capsule on the lens profile.
          Positioned(
            top: 620,
            left: 40,
            width: 200,
            height: 6,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          Positioned(
            top: 611,
            left: 110,
            width: 37,
            height: 24,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: LiquidGlassProfile.clear.shadow,
              ),
              child: labGlass(12, const Color(0xFFFFFFFF), 0.0,
                  profile: LiquidGlassProfile.clear),
            ),
          ),
          Positioned(
            top: 650,
            left: 40,
            width: 160,
            height: 50,
            child: labGlass(25, const Color(0xFF101014),
                DepthTokens.liquidControlTintOpacity,
                adaptiveMax: DepthTokens.liquidControlAdaptiveMax,
                child: labLabel(Icons.play_arrow_rounded, 'Play')),
          ),
          labTag(top: 594, left: 40, text: 'clear 37x24'),
          labTag(top: 706, left: 40, text: 'lens 50pt'),
          labTag(top: 224, left: 40, text: 'panel'),
          labTag(top: 124, left: 110, text: 'lens (prominent)'),
          labTag(top: 124, left: 40, text: 'lens'),
          Positioned(
            right: 16,
            bottom: 16,
            child: FilledButton(
              onPressed: () => setState(() => _grid = !_grid),
              child: Text(
                LiquidGlassSupport.available
                    ? 'Shader on: toggle grid'
                    : 'Shader OFF (frosted): toggle grid',
              ),
            ),
          ),
        ],
      );

  Widget _scrollEdgeBand() {
    const ground = Color(0xFF101014);
    final top =
        ground.withValues(alpha: DepthTokens.liquidScrollEdgeTopOpacity);
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: DepthTokens.liquidScrollEdgeBlurSigma,
          sigmaY: DepthTokens.liquidScrollEdgeBlurSigma,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.6, 1.0],
              colors: [
                top,
                top,
                ground.withValues(
                    alpha: DepthTokens.liquidScrollEdgeBottomOpacity),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.grid, required this.controller});

  final bool grid;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      itemCount: 60,
      itemBuilder: (context, i) => SizedBox(
        height: 72,
        child: grid
            ? CustomPaint(painter: _GridPainter())
            : Row(
                children: [
                  for (var c = 0; c < 6; c++)
                    Expanded(
                      child: Container(
                        color: HSVColor.fromAHSV(
                          1,
                          (i * 37 + c * 53) % 360.0,
                          0.7,
                          0.9,
                        ).toColor(),
                        alignment: Alignment.center,
                        child: Text(
                          'Row $i',
                          style: TextStyle(
                            color: c.isEven ? Colors.white : Colors.black,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final line = Paint()
      ..color = Colors.black
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var y = 0.0; y < size.height; y += 8) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => false;
}
