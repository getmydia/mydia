import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/toast/toaster.dart';

import '../../../test_utils/toast_harness.dart';

final _pill = find.byKey(const Key('toast-pill'));
const _body = Key('body');

/// Pumps an 800x600 app with a layer mounted the way `app.dart` mounts it,
/// and returns a context under it.
Future<BuildContext> _pumpLayer(
  WidgetTester tester, {
  bool reduceMotion = false,
  bool accessibleNavigation = false,
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reduceMotion,
        accessibleNavigation: accessibleNavigation,
      ),
      child: toastLayerBuilder(context, child),
    ),
    home: const Scaffold(body: SizedBox.expand(key: _body)),
  ));
  return tester.element(find.byKey(_body));
}

/// Lets the 200ms enter or exit transition finish.
Future<void> _settleMotion(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  testWidgets('Toaster.of without a layer names what is missing',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: SizedBox.expand(key: _body)));
    final context = tester.element(find.byKey(_body));
    expect(
      () => Toaster.of(context),
      throwsA(isA<FlutterError>()
          .having((e) => e.message, 'message', contains('No ToastLayer found'))
          // The hint names the one builder that fixes the call: losing it
          // would leave the reader with a complaint and no way out.
          .having((e) => e.message, 'hint', contains('toastLayerBuilder'))),
    );
  });

  testWidgets('shows a toast, then removes it after its duration',
      (tester) async {
    final context = await _pumpLayer(tester);
    showToast(context, 'Saved');
    await _settleMotion(tester);
    expect(find.text('Saved'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await _settleMotion(tester);
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('pumpAndSettle leaves a visible toast on screen', (tester) async {
    // Guards the Timer countdown. An animation-driven countdown would keep
    // scheduling frames and pumpAndSettle would run the toast out.
    final context = await _pumpLayer(tester);
    showToast(context, 'Saved');
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('unmounting the layer leaves no timer behind', (tester) async {
    // flutter_test fails the test itself if a Timer is still pending after
    // the tree is torn down, so reaching the end is the assertion.
    final context = await _pumpLayer(tester);
    showToast(context, 'Saved');
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rests 24px above the bottom, centred, with nothing in the way',
      (tester) async {
    final context = await _pumpLayer(tester);
    showToast(context, 'Saved');
    await tester.pumpAndSettle();
    final rect = tester.getRect(_pill);
    expect(rect.bottom, 600 - 24);
    expect(rect.center.dx, closeTo(400, 0.5));
  });

  testWidgets('a second toast replaces the first', (tester) async {
    final context = await _pumpLayer(tester);
    showToast(context, 'First');
    await _settleMotion(tester);
    showToast(context, 'Second');
    await _settleMotion(tester);
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets("closing a replaced toast's handle leaves the current one",
      (tester) async {
    final context = await _pumpLayer(tester);
    final first = showToast(context, 'First');
    await _settleMotion(tester);
    showToast(context, 'Second');
    await _settleMotion(tester);
    first.close();
    await _settleMotion(tester);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('progress stays until its handle closes it', (tester) async {
    final context = await _pumpLayer(tester);
    final loading =
        showToast(context, 'Loading subtitle...', kind: ToastKind.progress);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Loading subtitle...'), findsOneWidget);
    loading.close();
    await _settleMotion(tester);
    expect(find.text('Loading subtitle...'), findsNothing);
  });

  testWidgets('progress gives up after 30s', (tester) async {
    final context = await _pumpLayer(tester);
    showToast(context, 'Loading subtitle...', kind: ToastKind.progress);
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    await _settleMotion(tester);
    expect(find.text('Loading subtitle...'), findsNothing);
  });

  testWidgets('hovering pauses the timer and leaving restarts it',
      (tester) async {
    final context = await _pumpLayer(tester);
    showToast(context, 'Saved');
    await _settleMotion(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_pill));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Saved'), findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2900));
    expect(find.text('Saved'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    await _settleMotion(tester);
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('swiping down dismisses', (tester) async {
    final context = await _pumpLayer(tester);
    showToast(context, 'Saved');
    await _settleMotion(tester);
    await tester.drag(_pill, const Offset(0, 60));
    await _settleMotion(tester);
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('a slow nudge does not dismiss', (tester) async {
    final context = await _pumpLayer(tester);
    showToast(context, 'Saved');
    await _settleMotion(tester);
    await tester.timedDrag(
        _pill, const Offset(0, 10), const Duration(seconds: 1));
    await _settleMotion(tester);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('an action runs its callback and closes the toast',
      (tester) async {
    final context = await _pumpLayer(tester);
    var ran = false;
    showToast(context, 'Denied',
        kind: ToastKind.error,
        action: ToastAction(label: 'Settings', onPressed: () => ran = true));
    await _settleMotion(tester);
    await tester.tap(find.byKey(const Key('toast-action')));
    await _settleMotion(tester);
    expect(ran, isTrue);
    expect(find.text('Denied'), findsNothing);
  });

  testWidgets('with a screen reader an action toast waits to be dismissed',
      (tester) async {
    final context = await _pumpLayer(tester, accessibleNavigation: true);
    showToast(context, 'Denied',
        kind: ToastKind.error,
        action: ToastAction(label: 'Settings', onPressed: () {}));
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Denied'), findsOneWidget);
  });

  testWidgets('the toast never takes focus', (tester) async {
    final context = await _pumpLayer(tester);
    showToast(context, 'Denied',
        action: ToastAction(label: 'Settings', onPressed: () {}));
    await _settleMotion(tester);
    final node = Focus.of(tester.element(find.text('Settings')));
    expect(node.canRequestFocus, isFalse);
  });

  testWidgets('it rises into place', (tester) async {
    final context = await _pumpLayer(tester);
    showToast(context, 'Saved');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final midway = tester.getRect(_pill).top;
    await tester.pumpAndSettle();
    expect(midway, greaterThan(tester.getRect(_pill).top));
  });

  testWidgets('reduced motion fades without the rise', (tester) async {
    final context = await _pumpLayer(tester, reduceMotion: true);
    showToast(context, 'Saved');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final midway = tester.getRect(_pill).top;
    await tester.pumpAndSettle();
    expect(midway, tester.getRect(_pill).top);
  });

  testWidgets('a toast outlives the route that showed it', (tester) async {
    final context = await _pumpLayer(tester);
    showToast(context, 'Saved');
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: SizedBox.expand())));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('taps outside the pill reach the app underneath', (tester) async {
    var tapped = false;
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      builder: toastLayerBuilder,
      home: Scaffold(
        body: GestureDetector(
          key: _body,
          behavior: HitTestBehavior.opaque,
          onTap: () => tapped = true,
          child: const SizedBox.expand(),
        ),
      ),
    ));
    showToast(tester.element(find.byKey(_body)), 'Saved');
    await tester.pumpAndSettle();
    // Same height as the pill, far to its left: inside the toast region's
    // strip but outside the pill itself.
    await tester.tapAt(Offset(20, tester.getCenter(_pill).dy));
    expect(tapped, isTrue);
  });
}
