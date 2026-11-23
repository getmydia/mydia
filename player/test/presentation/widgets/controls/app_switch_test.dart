import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/controls/app_switch.dart';

final _palette = Palettes.oledBlack;

Widget _host(
  AppSwitch child, {
  bool liquid = false,
  bool disableAnimations = true,
}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(
        data: AppTheme.build(_palette, liquid: liquid),
        child: Material(child: Center(child: child)),
      ),
    ),
  );
}

Color _trackColor(WidgetTester tester) {
  final c = tester.widget<AnimatedContainer>(find.byKey(AppSwitch.trackKey));
  return (c.decoration! as BoxDecoration).color!;
}

/// Rasterised bytes of [child] hosted under a Liquid theme on iOS.
Future<List<int>> _pixels(WidgetTester tester, Widget child) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: AppTheme.build(_palette, liquid: true),
          child: Material(child: Center(child: child)),
        ),
      ),
    ),
  );
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    return (await image.toByteData())!.buffer.asUint8List();
  }))!;
}

void main() {
  testWidgets('Frosted draws a 40x24 track and 20 white thumb', (tester) async {
    await tester.pumpWidget(_host(AppSwitch(value: true, onChanged: (_) {})));
    final track = find.byKey(AppSwitch.trackKey);
    final thumb = find.byKey(AppSwitch.thumbKey);
    expect(tester.getSize(track), const Size(40, 24));
    expect(tester.getSize(thumb), const Size(20, 20));
    expect(_trackColor(tester), _palette.primary);
    expect(tester.getTopLeft(thumb).dx - tester.getTopLeft(track).dx, 18);
    final deco = tester.widget<DecoratedBox>(thumb).decoration as BoxDecoration;
    expect(deco.color, Colors.white);
    final trackDeco =
        tester.widget<AnimatedContainer>(track).decoration! as BoxDecoration;
    expect(trackDeco.borderRadius, BorderRadius.circular(12));

    await tester.pumpWidget(_host(AppSwitch(value: false, onChanged: (_) {})));
    expect(_trackColor(tester), _palette.border);
    expect(tester.getTopLeft(thumb).dx - tester.getTopLeft(track).dx, 2);
    expect(tester.getSize(thumb), const Size(20, 20));
  });

  testWidgets('hit target is 48 high', (tester) async {
    await tester.pumpWidget(_host(AppSwitch(value: false, onChanged: (_) {})));
    expect(
      tester.getSize(find.byType(AppSwitch)).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('tap toggles', (tester) async {
    final calls = <bool>[];
    await tester.pumpWidget(
      _host(AppSwitch(value: false, onChanged: calls.add)),
    );
    await tester.tap(find.byType(AppSwitch));
    expect(calls, [true]);
  });

  testWidgets('Select toggles exactly once', (tester) async {
    final calls = <bool>[];
    await tester.pumpWidget(
      _host(AppSwitch(value: true, onChanged: calls.add, autofocus: true)),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(calls, [false]);
  });

  testWidgets('disabled: dimmed, no focus, no callback', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      _host(
        AppSwitch(
          value: false,
          onChanged: null,
          focusNode: node,
          autofocus: true,
        ),
      ),
    );
    await tester.pump();
    expect(node.hasFocus, isFalse);
    expect(
      tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(AppSwitch),
              matching: find.byType(Opacity),
            ),
          )
          .opacity,
      0.38,
    );
  });

  testWidgets('semantics mirror value and enabled', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(AppSwitch(value: true, onChanged: (_) {})));
    expect(
      tester.getSemantics(find.byType(AppSwitch)),
      matchesSemantics(
        hasToggledState: true,
        isToggled: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    await tester.pumpWidget(
      _host(const AppSwitch(value: false, onChanged: null)),
    );
    expect(
      tester.getSemantics(find.byType(AppSwitch)),
      matchesSemantics(
        hasToggledState: true,
        isToggled: false,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('reduced motion moves the thumb without animation', (
    tester,
  ) async {
    await tester.pumpWidget(_host(AppSwitch(value: false, onChanged: (_) {})));
    await tester.pumpWidget(_host(AppSwitch(value: true, onChanged: (_) {})));
    await tester.pump();
    final thumb = find.byKey(AppSwitch.thumbKey);
    final track = find.byKey(AppSwitch.trackKey);
    expect(tester.getTopLeft(thumb).dx - tester.getTopLeft(track).dx, 18);
  });

  testWidgets('animates when motion is allowed', (tester) async {
    await tester.pumpWidget(
      _host(
        AppSwitch(value: false, onChanged: (_) {}),
        disableAnimations: false,
      ),
    );
    await tester.pumpWidget(
      _host(
        AppSwitch(value: true, onChanged: (_) {}),
        disableAnimations: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    final thumb = find.byKey(AppSwitch.thumbKey);
    final track = find.byKey(AppSwitch.trackKey);
    final dx = tester.getTopLeft(thumb).dx - tester.getTopLeft(track).dx;
    expect(dx, greaterThan(2));
    expect(dx, lessThan(18));
  });

  testWidgets('Liquid renders the stock Switch', (tester) async {
    await tester.pumpWidget(
      _host(AppSwitch(value: true, onChanged: (_) {}), liquid: true),
    );
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byKey(AppSwitch.trackKey), findsNothing);
  });

  for (final on in [false, true]) {
    testWidgets('focus ring keeps thumb geometry (value $on)', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      await tester.pumpWidget(
        _host(AppSwitch(value: on, onChanged: (_) {}, autofocus: true)),
      );
      await tester.pump();
      final thumb = find.byKey(AppSwitch.thumbKey);
      final track = find.byKey(AppSwitch.trackKey);
      final c = tester.widget<AnimatedContainer>(track);
      expect(c.foregroundDecoration, isNotNull);
      expect(tester.getSize(track), const Size(40, 24));
      expect(tester.getSize(thumb), const Size(20, 20));
      expect(
        tester.getTopLeft(thumb).dx - tester.getTopLeft(track).dx,
        on ? 18 : 2,
      );
    });
  }

  testWidgets(
    'Liquid adaptive draws Switch.adaptive on iOS, default does not',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final adaptive = await _pixels(
        tester,
        AppSwitch(value: true, onChanged: (_) {}, adaptive: true),
      );
      final plain = await _pixels(
        tester,
        AppSwitch(value: true, onChanged: (_) {}),
      );
      final reference = await _pixels(
        tester,
        Switch.adaptive(value: true, onChanged: (_) {}),
      );
      expect(adaptive, reference);
      expect(adaptive, isNot(plain));
    },
  );
}
