import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/glass/dry_liquid_glass.dart';
import 'package:player/presentation/widgets/glass/liquid_glass_filter.dart';
import 'package:player/presentation/widgets/glass/osd_glass.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/video_controls/touch_transport.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';
import 'package:player/presentation/widgets/video_controls/video_progress_bar.dart';

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}
}

enum _Mode { off, sampled, dry }

Widget _host(Widget child, _Mode mode) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: AppTheme.build(Palettes.projectionBooth, liquid: mode != _Mode.off),
  home: OsdGlassScope(
    surfaceOutput: mode == _Mode.dry,
    child: Scaffold(
      body: Center(child: SizedBox(width: 400, child: child)),
    ),
  ),
);

Future<void> _with(_Mode mode, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = mode == _Mode.off
      ? TargetPlatform.android
      : TargetPlatform.macOS;
  LiquidGlassSupport.debugOverride = true;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
    LiquidGlassSupport.debugOverride = null;
  }
}

void main() {
  late _FakePlatformPlayer platform;
  late Player player;

  setUp(() {
    platform = _FakePlatformPlayer();
    player = Player(platformPlayer: platform);
  });
  tearDown(() => player.dispose());

  Widget transport() =>
      TouchTransport(player: player, onBack10: () {}, onForward10: () {});

  Finder playDisc() => find.descendant(
    of: find.byKey(TransportSurface.playPauseKey),
    matching: find.byType(GlassSurface),
  );

  Color glyph(WidgetTester tester) => tester
      .widget<Icon>(
        find.descendant(
          of: find.byKey(TransportSurface.playPauseKey),
          matching: find.byType(Icon),
        ),
      )
      .color!;

  group('play disc', () {
    for (final mode in [_Mode.sampled, _Mode.dry]) {
      testWidgets('$mode is a circular glass pill with a white glyph', (
        tester,
      ) async {
        await _with(mode, () async {
          await tester.pumpWidget(_host(transport(), mode));
          expect(playDisc(), findsOneWidget);
          final surface = tester.widget<GlassSurface>(playDisc());
          expect(
            surface.borderRadius,
            BorderRadius.circular(TouchTransport.playSize / 2),
          );
          expect(glyph(tester), Palettes.projectionBooth.textPrimary);
          expect(
            tester.getSize(find.byKey(TransportSurface.playPauseKey)),
            const Size(TouchTransport.playSize, TouchTransport.playSize),
          );
        });
      });
    }

    testWidgets('buffering spinner is white on glass', (tester) async {
      await _with(_Mode.sampled, () async {
        platform.state = platform.state.copyWith(buffering: true);
        await tester.pumpWidget(_host(transport(), _Mode.sampled));
        final spinner = tester.widget<CircularProgressIndicator>(
          find.descendant(
            of: find.byKey(TouchTransport.bufferingKey),
            matching: find.byType(CircularProgressIndicator),
          ),
        );
        expect(spinner.color, Palettes.projectionBooth.textPrimary);
      });
    });

    testWidgets('off keeps the opaque disc and dark glyph', (tester) async {
      await _with(_Mode.off, () async {
        await tester.pumpWidget(_host(transport(), _Mode.off));
        expect(playDisc(), findsNothing);
        expect(glyph(tester), TouchTransport.playGlyph);
      });
    });
  });

  group('scrubber thumb', () {
    Widget bar() =>
        const ProgressBarSurface(progress: 0.4, buffered: 0.6, onSeekTo: _noop);

    Finder thumb() => find.byKey(ProgressBarSurface.thumbKey);

    // The seek bar stays off glass in every mode (spec, "Revision after
    // #1525"): a clear knob refracts the white played track and vanishes.
    for (final mode in [_Mode.off, _Mode.sampled, _Mode.dry]) {
      testWidgets('$mode keeps the plain white thumb', (tester) async {
        await _with(mode, () async {
          await tester.pumpWidget(_host(bar(), mode));
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: thumb(),
              matching: find.byType(LiquidGlassFilter),
            ),
            findsNothing,
          );
          expect(
            find.descendant(of: thumb(), matching: find.byType(DryLiquidGlass)),
            findsNothing,
          );
          final box = tester.widget<Container>(thumb()).decoration;
          expect((box! as BoxDecoration).color, Colors.white);
        });
      });
    }

    for (final mode in [_Mode.off, _Mode.sampled, _Mode.dry]) {
      testWidgets('$mode grows from nothing to 18 when focused', (
        tester,
      ) async {
        await _with(mode, () async {
          await tester.pumpWidget(_host(bar(), mode));
          await tester.pumpAndSettle();
          expect(tester.getSize(thumb()), Size.zero);
          await tester.pumpWidget(
            _host(
              const ProgressBarSurface(
                progress: 0.4,
                buffered: 0.6,
                onSeekTo: _noop,
                focused: true,
              ),
              mode,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.getSize(thumb()), const Size(18, 18));
        });
      });
    }
  });
}

void _noop(double _) {}
