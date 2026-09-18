import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/toast/toast_models.dart';
import 'package:player/presentation/widgets/toast/toast_pill.dart';

final _pill = find.byKey(const Key('toast-pill'));

ToastEntry _entry(
  String message, {
  ToastKind kind = ToastKind.info,
  IconData? icon,
  ToastAction? action,
}) =>
    ToastEntry(
      id: 0,
      message: message,
      kind: kind,
      icon: icon,
      action: action,
      duration: const Duration(seconds: 3),
    );

Future<void> _pump(WidgetTester tester, ToastEntry entry,
    {VoidCallback? onAction}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(child: ToastPill(entry: entry, onAction: onAction)),
    ),
  ));
}

Color? _iconColor(WidgetTester tester, IconData icon) =>
    tester.widget<Icon>(find.byIcon(icon)).color;

void main() {
  testWidgets('a short message sizes the pill to its content', (tester) async {
    await _pump(tester, _entry('Saved'));
    expect(tester.getSize(_pill).width, lessThan(200));
  });

  testWidgets('a long message caps at 420 wide and three lines',
      (tester) async {
    final message = List.filled(80, 'wordy').join(' ');
    await _pump(tester, _entry(message));
    expect(tester.getSize(_pill).width, ToastMetrics.maxWidth);
    final paragraph = tester.renderObject<RenderParagraph>(find.text(message));
    expect(paragraph.didExceedMaxLines, isTrue);
    expect(tester.widget<Text>(find.text(message)).maxLines, 3);
  });

  testWidgets('info shows no glyph unless given one', (tester) async {
    await _pump(tester, _entry('Plain'));
    expect(find.byType(Icon), findsNothing);

    await _pump(tester, _entry('Queued', icon: Icons.download_rounded));
    expect(_iconColor(tester, Icons.download_rounded), AppColors.textSecondary);
  });

  testWidgets('success is a green check', (tester) async {
    await _pump(tester, _entry('Saved', kind: ToastKind.success));
    expect(_iconColor(tester, Icons.check_circle_rounded), AppColors.success);
  });

  testWidgets('error is a red alert', (tester) async {
    await _pump(tester, _entry('Failed', kind: ToastKind.error));
    expect(_iconColor(tester, Icons.error_rounded), AppColors.error);
  });

  testWidgets('progress is a gold spinner', (tester) async {
    await _pump(tester, _entry('Loading...', kind: ToastKind.progress));
    final spinner = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator));
    expect(spinner.color, AppColors.primary);
  });

  testWidgets('no kind recolours the pill itself', (tester) async {
    for (final kind in ToastKind.values) {
      await _pump(tester, _entry('Same glass', kind: kind));
      final glass = tester.widget<GlassSurface>(find.byType(GlassSurface));
      expect(glass.fillColor, ToastPill.fill, reason: '$kind');
    }
  });

  test('the fill clears the legibility floor', () {
    expect(ToastPill.fill.a,
        greaterThanOrEqualTo(DepthTokens.glassLegibilityFloor));
  });

  testWidgets('an action is a gold text button that fires onAction',
      (tester) async {
    var pressed = 0;
    await _pump(
      tester,
      _entry('Denied',
          kind: ToastKind.error,
          action: ToastAction(label: 'Settings', onPressed: () {})),
      onAction: () => pressed++,
    );
    final label = find.text('Settings');
    expect(DefaultTextStyle.of(tester.element(label)).style.color,
        AppColors.primary);
    await tester.tap(find.byKey(const Key('toast-action')));
    expect(pressed, 1);
  });

  testWidgets('screen readers hear it as a live region', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _entry('Saved'));
    expect(tester.getSemantics(_pill), containsSemantics(isLiveRegion: true));
    semantics.dispose();
  });

  testWidgets('a long action label is bounded instead of overrunning the pill',
      (tester) async {
    final message = List.filled(80, 'wordy').join(' ');
    const label = 'Open the notification settings panel';
    await _pump(
      tester,
      _entry(message,
          kind: ToastKind.error,
          action: ToastAction(label: label, onPressed: () {})),
    );
    expect(tester.takeException(), isNull);
    expect(
        tester.getSize(_pill).width, lessThanOrEqualTo(ToastMetrics.maxWidth));
    final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
    expect(paragraph.didExceedMaxLines, isTrue);
    expect(tester.widget<Text>(find.text(label)).maxLines, 1);
    expect(tester.getRect(find.byKey(const Key('toast-action'))).right,
        lessThanOrEqualTo(tester.getRect(_pill).right + 0.01));
  });

  testWidgets('a short action label leaves the message the pill width',
      (tester) async {
    final message = List.filled(80, 'wordy').join(' ');
    await _pump(
      tester,
      _entry(message,
          kind: ToastKind.error,
          action: ToastAction(label: 'Retry', onPressed: () {})),
    );
    expect(tester.getSize(find.text(message)).width,
        greaterThan(ToastMetrics.maxWidth / 2),
        reason: 'the message, not the button, owns the pill width');
  });
}
