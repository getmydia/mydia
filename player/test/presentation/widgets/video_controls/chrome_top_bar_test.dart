import 'package:material_ui/material_ui.dart';

import 'dart:ui' show SemanticsAction;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/core/player/video_scaling.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/video_controls/chrome_top_bar.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: Colors.white)),
        child,
      ],
    ),
  ),
);

void main() {
  group('ChromeTopBar', () {
    testWidgets('the back disc fires onBack', (tester) async {
      var backed = false;
      await tester.pumpWidget(_host(ChromeTopBar(onBack: () => backed = true)));

      await tester.tap(find.byKey(ChromeTopBar.backKey));
      expect(backed, isTrue);
    });

    testWidgets('the top bar has no text', (tester) async {
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            onBack: () {},
            onScalingTap: () {},
            castAction: const Icon(Icons.cast_rounded),
            trailing: const SizedBox(width: 40, height: 32),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(ChromeTopBar),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
      expect(find.byKey(ChromeTopBar.titleKey), findsNothing);
    });

    testWidgets('sideFor is 40 off the phone and 36 on it', (tester) async {
      expect(ChromeTopBar.sideFor(compact: false), 40);
      expect(ChromeTopBar.sideFor(compact: true), 36);
    });

    for (final compact in [false, true]) {
      testWidgets('the back disc is a circular osdPill square (compact: '
          '$compact)', (tester) async {
        final side = ChromeTopBar.sideFor(compact: compact);
        await tester.pumpWidget(
          _host(ChromeTopBar(onBack: () {}, compact: compact)),
        );

        expect(
          tester.getSize(find.byKey(ChromeTopBar.backKey)),
          Size(side, side),
        );
        expect(
          tester.getSize(find.byKey(ChromeTopBar.backDiscKey)),
          Size(side, side),
        );
        final disc = tester.widget<GlassSurface>(
          find.byKey(ChromeTopBar.backDiscKey),
        );
        expect(disc.osdRole, OsdRole.pill);
        expect(disc.borderRadius, BorderRadius.circular(side / 2));
      });
    }

    testWidgets('the back disc is inert when onBack is null', (tester) async {
      await tester.pumpWidget(_host(const ChromeTopBar()));

      expect(find.byKey(ChromeTopBar.backDiscKey), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(ChromeTopBar.backKey),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });

    testWidgets('showBack: false renders no disc', (tester) async {
      await tester.pumpWidget(
        _host(ChromeTopBar(showBack: false, onBack: () {})),
      );

      expect(find.byKey(ChromeTopBar.backKey), findsNothing);
      expect(find.byKey(ChromeTopBar.backDiscKey), findsNothing);
    });

    testWidgets('the remote tier (no back, cast or scaling) paints nothing', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const ChromeTopBar(showBack: false)));

      expect(
        find.descendant(
          of: find.byType(ChromeTopBar),
          matching: find.byType(GlassSurface),
        ),
        findsNothing,
      );
    });

    testWidgets('omits the cast pill when no action is supplied', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const ChromeTopBar()));
      expect(find.byKey(ChromeTopBar.castKey), findsNothing);
    });

    testWidgets('shows the cast pill when an action is supplied', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const ChromeTopBar(castAction: Icon(Icons.cast_rounded))),
      );
      expect(find.byKey(ChromeTopBar.castKey), findsOneWidget);
    });

    testWidgets('the cast pill fires onCastTap across its whole surface', (
      tester,
    ) async {
      var casted = false;
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            castAction: const Icon(Icons.cast_rounded),
            onCastTap: () => casted = true,
          ),
        ),
      );

      await tester.tap(find.byKey(ChromeTopBar.castKey));
      expect(casted, isTrue);
    });

    testWidgets('the cast pill is inert when onCastTap is null', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const ChromeTopBar(castAction: Icon(Icons.cast_rounded))),
      );

      expect(
        find.descendant(
          of: find.byKey(ChromeTopBar.castKey),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });

    testWidgets('cast and scaling share one pill', (tester) async {
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            onScalingTap: () {},
            castAction: const Icon(Icons.cast_rounded),
            onCastTap: () {},
          ),
        ),
      );

      for (final key in [ChromeTopBar.scalingKey, ChromeTopBar.castKey]) {
        expect(
          find.descendant(
            of: find.byKey(ChromeTopBar.actionsPillKey),
            matching: find.byKey(key),
          ),
          findsOneWidget,
        );
      }
    });

    for (final compact in [false, true]) {
      testWidgets('the actions capsule is sideFor tall with the right glyphs '
          '(compact: $compact)', (tester) async {
        final side = ChromeTopBar.sideFor(compact: compact);
        final glyph = compact ? 19.0 : 20.0;
        await tester.pumpWidget(
          _host(
            ChromeTopBar(
              onBack: () {},
              onScalingTap: () {},
              castAction: const Icon(Icons.cast_rounded),
              onCastTap: () {},
              compact: compact,
            ),
          ),
        );

        expect(
          tester.getSize(find.byKey(ChromeTopBar.actionsPillKey)).height,
          side,
        );
        expect(tester.getSize(find.byKey(ChromeTopBar.castKey)).height, side);
        expect(
          tester.getSize(find.byKey(ChromeTopBar.scalingKey)).height,
          side,
        );
        expect(
          tester
              .widget<Icon>(
                find.descendant(
                  of: find.byKey(ChromeTopBar.scalingKey),
                  matching: find.byIcon(Icons.fit_screen_rounded),
                ),
              )
              .size,
          glyph,
        );
        expect(
          IconTheme.of(tester.element(find.byIcon(Icons.cast_rounded))).size,
          glyph,
        );
      });
    }

    testWidgets('trailing sits in its own pill, as tall as the actions pill', (
      tester,
    ) async {
      const trailing = SizedBox(key: Key('trailing'), width: 96, height: 32);
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            onScalingTap: () {},
            castAction: const Icon(Icons.cast_rounded),
            trailing: trailing,
            compact: true,
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byKey(ChromeTopBar.trailingPillKey),
          matching: find.byKey(const Key('trailing')),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(ChromeTopBar.trailingPillKey)).height,
        ChromeTopBar.sideFor(compact: true),
      );
      expect(
        tester.getSize(find.byKey(ChromeTopBar.actionsPillKey)).height,
        ChromeTopBar.sideFor(compact: true),
      );
      expect(
        tester.getRect(find.byKey(ChromeTopBar.trailingPillKey)).right,
        lessThan(tester.getRect(find.byKey(ChromeTopBar.actionsPillKey)).left),
      );
    });

    testWidgets('compact narrows the gaps between pills', (tester) async {
      Future<double> pillGap({required bool compact}) async {
        await tester.pumpWidget(
          _host(
            ChromeTopBar(
              onScalingTap: () {},
              trailing: const SizedBox(width: 40, height: 32),
              compact: compact,
            ),
          ),
        );
        return tester.getRect(find.byKey(ChromeTopBar.actionsPillKey)).left -
            tester.getRect(find.byKey(ChromeTopBar.trailingPillKey)).right;
      }

      expect(await pillGap(compact: false), ChromeTopBar.gap);
      expect(await pillGap(compact: true), ChromeTopBar.compactGap);
    });

    for (final width in <double>[240, 280, 300]) {
      testWidgets('the pills scale down rather than overflow at ${width}px', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _host(
            ChromeTopBar(
              onBack: () {},
              onScalingTap: () {},
              castAction: const Icon(Icons.cast_rounded),
              trailing: const SizedBox(width: 4 * 32, height: 32),
              compact: true,
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byKey(ChromeTopBar.actionsPillKey)).right,
          lessThanOrEqualTo(width + 0.5),
        );
      });
    }

    testWidgets('the actions pill is omitted with neither action', (
      tester,
    ) async {
      await tester.pumpWidget(_host(ChromeTopBar(onBack: () {})));
      expect(find.byKey(ChromeTopBar.actionsPillKey), findsNothing);
    });

    testWidgets('back is an icon with a Back tooltip, no visible label', (
      tester,
    ) async {
      await tester.pumpWidget(_host(ChromeTopBar(onBack: () {})));

      expect(find.text('Back'), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Back'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ChromeTopBar.backKey),
          matching: find.byIcon(Icons.chevron_left_rounded),
        ),
        findsOneWidget,
      );
    });

    testWidgets('semantics: one button labelled Back', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        var backed = false;
        await tester.pumpWidget(
          _host(ChromeTopBar(onBack: () => backed = true)),
        );

        final node = tester.getSemantics(find.byKey(ChromeTopBar.backKey));
        expect(node.label, 'Back');
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        expect(find.semantics.byLabel('Back'), findsOne);
        tester.semantics.tap(find.semantics.byLabel('Back'));
        await tester.pump();
        expect(backed, isTrue);
      } finally {
        handle.dispose();
      }
    });

    testWidgets('back leads on the right and the actions on the left in RTL', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          Directionality(
            textDirection: TextDirection.rtl,
            child: ChromeTopBar(onBack: () {}, onScalingTap: () {}),
          ),
        ),
      );

      final back = tester.getRect(find.byKey(ChromeTopBar.backKey));
      final actions = tester.getRect(find.byKey(ChromeTopBar.actionsPillKey));
      final bar = tester.getRect(find.byType(ChromeTopBar));
      expect(back.left, greaterThan(actions.right));
      expect(back.right, closeTo(bar.right, 0.5));
    });

    testWidgets('top bar contains no BackdropFilter', (tester) async {
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            onBack: () {},
            onScalingTap: () {},
            castAction: const Icon(Icons.cast_rounded),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(ChromeTopBar),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
    });

    for (final width in const [280.0, 320.0, 360.0]) {
      testWidgets('back, scaling and cast all fit at ${width}px', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _host(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ChromeTopBar(
                onBack: () {},
                onScalingTap: () {},
                castAction: const Icon(Icons.cast_rounded),
                onCastTap: () {},
                trailing: const SizedBox(width: 3 * 32 + 8, height: 32),
                compact: true,
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        for (final key in [
          ChromeTopBar.backKey,
          ChromeTopBar.scalingKey,
          ChromeTopBar.castKey,
        ]) {
          final rect = tester.getRect(find.byKey(key));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
        }
      });
    }

    testWidgets('omits the scaling pill when no handler is wired', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const ChromeTopBar()));

      expect(find.byKey(ChromeTopBar.scalingKey), findsNothing);
    });

    testWidgets('scaling pill shows the current mode and fires', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          ChromeTopBar(onScalingTap: () => taps++, scaling: VideoScaling.fill),
        ),
      );

      expect(
        find.descendant(
          of: find.byKey(ChromeTopBar.scalingKey),
          matching: find.byIcon(Icons.crop_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(ChromeTopBar.scalingKey));
      expect(taps, 1);
    });

    testWidgets('scaling pill sits left of the cast pill', (tester) async {
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            onScalingTap: () {},
            castAction: const Icon(Icons.cast_rounded),
            onCastTap: () {},
          ),
        ),
      );

      expect(
        tester.getRect(find.byKey(ChromeTopBar.scalingKey)).right,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(ChromeTopBar.castKey)).left,
        ),
      );
    });
  });

  group('GlassPill', () {
    testWidgets('sits on the OSD material with the pill shadow', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const Align(
            alignment: Alignment.topLeft,
            child: GlassPill(child: Text('Back')),
          ),
        ),
      );

      final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
      expect(surface.shadows, DepthTokens.osdShadowPill);
      expect(
        surface.borderRadius,
        const BorderRadius.all(Radius.circular(DepthTokens.radiusOsdPill)),
      );
    });

    testWidgets('top bar glyphs carry no shadow', (tester) async {
      await tester.pumpWidget(_host(ChromeTopBar(onBack: () {})));

      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(ChromeTopBar.backKey),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.shadows, isNull);
    });

    testWidgets('is 36px tall', (tester) async {
      await tester.pumpWidget(
        _host(
          const Align(
            alignment: Alignment.topLeft,
            child: GlassPill(child: Text('Back')),
          ),
        ),
      );

      expect(tester.getSize(find.byType(GlassPill)).height, 36);
    });

    testWidgets('fires onTap when supplied', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          Align(
            alignment: Alignment.topLeft,
            child: GlassPill(
              onTap: () => tapped = true,
              child: const Text('Tap me'),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(GlassPill));
      expect(tapped, isTrue);
    });
  });

  group('GlassPill height', () {
    testWidgets('defaults to defaultHeight', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: GlassPill(key: Key('default-pill'), child: Text('Back')),
            ),
          ),
        ),
      );

      expect(
        tester.getSize(find.byKey(const Key('default-pill'))).height,
        GlassPill.defaultHeight,
      );
    });

    testWidgets('honors an explicit height', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: GlassPill(
                key: Key('tall-pill'),
                height: 44,
                child: Text('Next up'),
              ),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(const Key('tall-pill'))).height, 44.0);
    });
  });
}
